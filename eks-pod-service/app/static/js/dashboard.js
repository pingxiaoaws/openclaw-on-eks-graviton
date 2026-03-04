// Dashboard page logic
const Dashboard = {
    currentInstance: null,
    refreshTimer: null,

    // Initialize dashboard
    init() {
        console.log('🚀 Dashboard initializing...');

        // Check authentication
        if (!Auth.init()) {
            console.log('❌ Not authenticated, redirecting to login');
            window.location.href = '/login';
            return;
        }

        // Display user email
        const userEmail = Auth.getUserEmail();
        document.getElementById('user-email').textContent = userEmail;

        // Setup event listeners
        this.setupEventListeners();

        // Load user's instance
        this.loadInstance();

        // Setup auto-refresh
        this.startAutoRefresh();
    },

    // Setup event listeners
    setupEventListeners() {
        // Logout button
        document.getElementById('logout-btn').addEventListener('click', () => {
            this.handleLogout();
        });

        // Create instance button
        document.getElementById('create-instance-btn').addEventListener('click', () => {
            this.handleCreateInstance();
        });

        // Refresh button
        document.getElementById('refresh-btn').addEventListener('click', () => {
            this.loadInstance();
        });

        // Delete button
        document.getElementById('delete-btn').addEventListener('click', () => {
            this.handleDeleteInstance();
        });

        // Connect button
        document.getElementById('connect-btn').addEventListener('click', () => {
            this.handleConnectInstance();
        });

        // Copy gateway endpoint button
        const copyBtn = document.getElementById('copy-gateway-btn');
        if (copyBtn) {
            copyBtn.addEventListener('click', () => {
                this.copyGatewayEndpoint();
            });
        }

        // Runtime selector toggle
        document.querySelectorAll('.runtime-option').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('.runtime-option').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
            });
        });
    },

    // Handle logout
    handleLogout() {
        this.stopAutoRefresh();
        Auth.logout();
        window.location.href = '/login';
    },

    // Load user's instance
    async loadInstance() {
        this.showLoading(true);
        this.hideError();

        try {
            const instance = await API.getMyInstance();
            this.currentInstance = instance;

            if (instance) {
                this.showInstance(instance);
            } else {
                this.showEmptyState();
            }
        } catch (error) {
            console.error('Failed to load instance:', error);
            this.showError(`Failed to load instance: ${error.message}`);
            this.showEmptyState();
        } finally {
            this.showLoading(false);
        }
    },

    // Show empty state (no instance)
    showEmptyState() {
        document.getElementById('empty-state').classList.remove('hidden');
        document.getElementById('instance-display').classList.add('hidden');

        // Disable create button if instance exists but failed to load
        if (this.currentInstance) {
            document.getElementById('create-instance-btn').disabled = true;
        } else {
            document.getElementById('create-instance-btn').disabled = false;
        }
    },

    // Show instance details
    showInstance(instance) {
        document.getElementById('empty-state').classList.add('hidden');
        document.getElementById('instance-display').classList.remove('hidden');

        // Update instance details
        document.getElementById('instance-id').textContent = instance.user_id;
        document.getElementById('instance-namespace').textContent = instance.namespace;
        document.getElementById('instance-created').textContent = new Date(instance.created_at).toLocaleString();

        // Update status badge with detailed message
        const statusEl = document.getElementById('instance-status');
        const status = instance.status || 'Pending';
        const statusMessage = instance.status_message || status;
        statusEl.textContent = statusMessage;
        statusEl.className = `status-badge status-${status.toLowerCase()}`;

        // Update runtime badge
        const runtimeEl = document.getElementById('instance-runtime');
        if (runtimeEl) {
            const runtimeClass = instance.runtime_class || null;
            if (runtimeClass && runtimeClass.startsWith('kata')) {
                runtimeEl.innerHTML = '<span class="runtime-badge runtime-kata">🛡️ Secure VM (' + runtimeClass + ')</span>';
            } else {
                runtimeEl.innerHTML = '<span class="runtime-badge runtime-runc">📦 Standard (runc)</span>';
            }
        }

        // Update storage badge
        const storageEl = document.getElementById('instance-storage');
        if (storageEl) {
            const storageClass = instance.storage_class || 'efs-sc';
            if (storageClass === 'gp3') {
                storageEl.innerHTML = '<span class="runtime-badge runtime-kata">💾 EBS (gp3)</span>';
            } else {
                storageEl.innerHTML = '<span class="runtime-badge runtime-runc">📂 EFS (elastic)</span>';
            }
        }

        // Update gateway endpoint
        const gatewayEl = document.getElementById('instance-gateway');
        if (instance.gateway_endpoint) {
            gatewayEl.textContent = instance.gateway_endpoint;
            document.getElementById('copy-gateway-btn').disabled = false;
        } else {
            gatewayEl.textContent = 'Not available yet';
            document.getElementById('copy-gateway-btn').disabled = true;
        }

        // Update connect button based on ready_for_connect flag
        const connectBtn = document.getElementById('connect-btn');
        const readyForConnect = instance.ready_for_connect === true;

        if (readyForConnect) {
            connectBtn.disabled = false;
            connectBtn.innerHTML = '<span>🔗</span> Connect to Gateway';
        } else {
            connectBtn.disabled = true;
            // Show specific waiting message
            if (instance.status_message) {
                connectBtn.innerHTML = `<span>⏳</span> ${instance.status_message}`;
            } else {
                connectBtn.innerHTML = '<span>⏳</span> Starting...';
            }
        }

        // Disable create button when instance exists
        document.getElementById('create-instance-btn').disabled = true;
    },

    // Handle create instance
    async handleCreateInstance() {
        if (this.currentInstance) {
            this.showError('You already have an instance. Please delete it first.');
            return;
        }

        // Get selected runtime
        const selectedRuntime = document.querySelector('.runtime-option.active')?.dataset.runtime || 'runc';
        const runtimeLabel = selectedRuntime === 'kata-qemu' ? 'Secure VM (Kata)' : 'Standard';
        const storageLabel = selectedRuntime === 'kata-qemu' ? 'EBS (gp3)' : 'EFS (elastic)';

        if (!confirm(`Create a new OpenClaw instance?\n\nRuntime: ${runtimeLabel}\nStorage: ${storageLabel}\n\nThis may take a few minutes.`)) {
            return;
        }

        const createBtn = document.getElementById('create-instance-btn');
        createBtn.disabled = true;
        createBtn.innerHTML = '<span>⏳</span> Creating...';
        this.hideError();

        try {
            const result = await API.createInstance(selectedRuntime);
            console.log('Instance created:', result);

            this.showSuccess('Instance creation started! Refreshing...');

            // Refresh after a delay
            setTimeout(() => this.loadInstance(), 3000);
        } catch (error) {
            console.error('Failed to create instance:', error);
            this.showError(`Failed to create instance: ${error.message}`);
            createBtn.disabled = false;
            createBtn.innerHTML = '<span>➕</span> Create OpenClaw Instance';
        }
    },

    // Handle delete instance
    async handleDeleteInstance() {
        if (!this.currentInstance) {
            return;
        }

        const confirmation = prompt(
            `⚠️ WARNING: This will permanently delete your OpenClaw instance.\n\n` +
            `Type "DELETE" to confirm:`
        );

        if (confirmation !== 'DELETE') {
            return;
        }

        this.hideError();

        try {
            await API.deleteInstance(this.currentInstance.user_id);
            console.log('Instance deleted');

            this.showSuccess('Instance deleted successfully!');
            this.currentInstance = null;

            setTimeout(() => this.loadInstance(), 2000);
        } catch (error) {
            console.error('Failed to delete instance:', error);
            this.showError(`Failed to delete instance: ${error.message}`);
        }
    },

    // Handle connect to instance
    async handleConnectInstance() {
        if (!this.currentInstance || !this.currentInstance.gateway_endpoint) {
            return;
        }

        try {
            await API.openInstance(this.currentInstance);
        } catch (error) {
            console.error('Failed to connect:', error);
            this.showError(`Failed to connect: ${error.message}`);
        }
    },

    // Copy gateway endpoint to clipboard
    copyGatewayEndpoint() {
        if (!this.currentInstance || !this.currentInstance.gateway_endpoint) {
            return;
        }

        const endpoint = this.currentInstance.gateway_endpoint;
        navigator.clipboard.writeText(endpoint).then(() => {
            const copyBtn = document.getElementById('copy-gateway-btn');
            const originalText = copyBtn.textContent;
            copyBtn.textContent = '✓ Copied!';
            setTimeout(() => {
                copyBtn.textContent = originalText;
            }, 2000);
        }).catch(err => {
            console.error('Failed to copy:', err);
            this.showError('Failed to copy to clipboard');
        });
    },

    // Show/hide loading
    showLoading(show) {
        const loadingEl = document.getElementById('loading');
        if (show) {
            loadingEl.classList.remove('hidden');
        } else {
            loadingEl.classList.add('hidden');
        }
    },

    // Show error message
    showError(message) {
        const errorEl = document.getElementById('error-message');
        errorEl.textContent = '❌ ' + message;
        errorEl.className = 'error-banner';
        errorEl.classList.remove('hidden');
    },

    // Show success message
    showSuccess(message) {
        const errorEl = document.getElementById('error-message');
        errorEl.textContent = '✅ ' + message;
        errorEl.className = 'error-banner success-banner';
        errorEl.classList.remove('hidden');

        // Auto-hide after 5 seconds
        setTimeout(() => this.hideError(), 5000);
    },

    // Hide error message
    hideError() {
        const errorEl = document.getElementById('error-message');
        errorEl.classList.add('hidden');
    },

    // Start auto-refresh
    startAutoRefresh() {
        this.stopAutoRefresh();
        this.refreshTimer = setInterval(() => {
            // Only auto-refresh if instance exists
            if (this.currentInstance) {
                this.loadInstance();
            }
        }, CONFIG.REFRESH_INTERVAL);
    },

    // Stop auto-refresh
    stopAutoRefresh() {
        if (this.refreshTimer) {
            clearInterval(this.refreshTimer);
            this.refreshTimer = null;
        }
    }
};

// Initialize dashboard when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    Dashboard.init();
});

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
    Dashboard.stopAutoRefresh();
});
