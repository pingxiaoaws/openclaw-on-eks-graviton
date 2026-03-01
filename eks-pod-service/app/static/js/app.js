// Main application logic
const App = {
    currentInstance: null,
    refreshTimer: null,

    // Initialize application
    async init() {
        console.log('🚀 OpenClaw Dashboard initializing...');

        // Check authentication
        if (Auth.init()) {
            this.showDashboard();
        } else {
            this.showLogin();
        }

        // Setup event listeners
        this.setupEventListeners();
    },

    // Setup event listeners
    setupEventListeners() {
        // Login form
        const loginForm = document.getElementById('login-form');
        if (loginForm) {
            loginForm.addEventListener('submit', async (e) => {
                e.preventDefault();
                await this.handleLogin();
            });
        }

        // Logout button
        const logoutBtn = document.getElementById('logout-btn');
        if (logoutBtn) {
            logoutBtn.addEventListener('click', () => this.handleLogout());
        }

        // Create instance button
        const createBtn = document.getElementById('create-instance-btn');
        if (createBtn) {
            createBtn.addEventListener('click', () => this.handleCreateInstance());
        }

        // Refresh button
        const refreshBtn = document.getElementById('refresh-btn');
        if (refreshBtn) {
            refreshBtn.addEventListener('click', () => this.loadInstances());
        }
    },

    // Show login screen
    showLogin() {
        document.getElementById('login-screen').classList.remove('hidden');
        document.getElementById('dashboard-screen').classList.add('hidden');
    },

    // Show dashboard screen
    showDashboard() {
        document.getElementById('login-screen').classList.add('hidden');
        document.getElementById('dashboard-screen').classList.remove('hidden');

        // Display user email
        const userEmail = Auth.getUserEmail();
        document.getElementById('user-email').textContent = userEmail;

        // Load instances
        this.loadInstances();

        // Setup auto-refresh
        this.startAutoRefresh();
    },

    // Handle login
    async handleLogin() {
        const email = document.getElementById('email').value;
        const password = document.getElementById('password').value;
        const errorEl = document.getElementById('login-error');
        const submitBtn = document.querySelector('#login-form button[type="submit"]');

        errorEl.textContent = '';
        submitBtn.disabled = true;
        submitBtn.textContent = 'Signing in...';

        try {
            await Auth.signIn(email, password);
            this.showDashboard();
        } catch (error) {
            errorEl.textContent = `Login failed: ${error.message}`;
        } finally {
            submitBtn.disabled = false;
            submitBtn.textContent = 'Sign In';
        }
    },

    // Handle logout
    handleLogout() {
        this.stopAutoRefresh();
        Auth.logout();
        this.showLogin();
    },

    // Load instances
    async loadInstances() {
        this.showLoading(true);
        this.hideError();

        try {
            const instance = await API.getMyInstance();
            this.currentInstance = instance;
            this.renderInstances(instance);
        } catch (error) {
            console.error('Failed to load instances:', error);
            this.showError(`Failed to load instances: ${error.message}`);
            this.renderInstances(null);
        } finally {
            this.showLoading(false);
        }
    },

    // Render instances
    renderInstances(instance) {
        const noInstancesEl = document.getElementById('no-instances');
        const instancesGrid = document.getElementById('instances-grid');

        if (!instance) {
            noInstancesEl.classList.remove('hidden');
            instancesGrid.innerHTML = '';
            return;
        }

        noInstancesEl.classList.add('hidden');
        instancesGrid.innerHTML = this.createInstanceCard(instance);

        // Setup instance card event listeners
        this.setupInstanceCardListeners();
    },

    // Create instance card HTML
    createInstanceCard(instance) {
        const statusClass = `status-${(instance.status || 'pending').toLowerCase()}`;
        const statusText = instance.status || 'Pending';

        return `
            <div class="instance-card" data-user-id="${instance.user_id}">
                <div class="instance-header">
                    <div class="instance-id">openclaw-${instance.user_id}</div>
                    <span class="status-badge ${statusClass}">${statusText}</span>
                </div>

                <div class="instance-info">
                    <div class="info-row">
                        <span class="info-label">User ID:</span>
                        <span class="info-value">${instance.user_id}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Namespace:</span>
                        <span class="info-value">${instance.namespace}</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Created:</span>
                        <span class="info-value">${new Date(instance.created_at).toLocaleString()}</span>
                    </div>
                </div>

                ${instance.gateway_endpoint ? `
                    <div class="instance-gateway">
                        🌐 ${instance.gateway_endpoint}
                    </div>
                ` : ''}

                <div class="instance-actions">
                    ${instance.status === 'Running' ? `
                        <button class="btn btn-success connect-btn" data-user-id="${instance.user_id}">
                            <span>🔗</span> Connect
                        </button>
                    ` : `
                        <button class="btn btn-secondary" disabled>
                            <span>⏳</span> Starting...
                        </button>
                    `}
                    <button class="btn btn-danger delete-btn" data-user-id="${instance.user_id}">
                        <span>🗑️</span> Delete
                    </button>
                </div>
            </div>
        `;
    },

    // Setup instance card listeners
    setupInstanceCardListeners() {
        // Connect buttons
        document.querySelectorAll('.connect-btn').forEach(btn => {
            btn.addEventListener('click', async (e) => {
                const userId = e.currentTarget.dataset.userId;
                await this.handleConnectInstance(userId);
            });
        });

        // Delete buttons
        document.querySelectorAll('.delete-btn').forEach(btn => {
            btn.addEventListener('click', async (e) => {
                const userId = e.currentTarget.dataset.userId;
                await this.handleDeleteInstance(userId);
            });
        });
    },

    // Handle create instance
    async handleCreateInstance() {
        const createBtn = document.getElementById('create-instance-btn');

        if (this.currentInstance) {
            alert('You already have an active instance. Please delete it first if you want to create a new one.');
            return;
        }

        if (!confirm('Create a new OpenClaw instance? This may take a few minutes.')) {
            return;
        }

        createBtn.disabled = true;
        createBtn.innerHTML = '<span>⏳</span> Creating...';
        this.hideError();

        try {
            const result = await API.createInstance();
            console.log('Instance created:', result);

            // Show success message
            this.showError('Instance creation started! Refreshing...', 'success');

            // Refresh after a delay
            setTimeout(() => this.loadInstances(), 3000);
        } catch (error) {
            console.error('Failed to create instance:', error);
            this.showError(`Failed to create instance: ${error.message}`);
        } finally {
            createBtn.disabled = false;
            createBtn.innerHTML = '<span>➕</span> Create New Instance';
        }
    },

    // Handle connect to instance
    async handleConnectInstance(userId) {
        try {
            const instance = this.currentInstance;
            if (!instance || instance.user_id !== userId) {
                throw new Error('Instance not found');
            }

            await API.openInstance(instance);
        } catch (error) {
            console.error('Failed to connect to instance:', error);
            alert(`Failed to connect: ${error.message}`);
        }
    },

    // Handle delete instance
    async handleDeleteInstance(userId) {
        if (!confirm('Are you sure you want to delete this instance? This action cannot be undone.')) {
            return;
        }

        this.hideError();

        try {
            await API.deleteInstance(userId);
            console.log('Instance deleted:', userId);

            // Show success and refresh
            this.showError('Instance deleted successfully!', 'success');
            setTimeout(() => this.loadInstances(), 2000);
        } catch (error) {
            console.error('Failed to delete instance:', error);
            this.showError(`Failed to delete instance: ${error.message}`);
        }
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
    showError(message, type = 'error') {
        const errorEl = document.getElementById('error-message');
        errorEl.textContent = message;
        errorEl.className = type === 'success' ? 'error-banner success-banner' : 'error-banner';
        errorEl.classList.remove('hidden');

        // Auto-hide success messages
        if (type === 'success') {
            setTimeout(() => this.hideError(), 5000);
        }
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
            this.loadInstances();
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

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    App.init();
});

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
    App.stopAutoRefresh();
});
