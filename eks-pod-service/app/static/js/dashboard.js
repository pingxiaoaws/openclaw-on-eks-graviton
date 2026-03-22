// WebSocket Manager for OpenClaw Gateway connections
class WebSocketManager {
    constructor() {
        this.ws = null;
        this.isConnected = false;
        this.reconnectAttempts = 0;
        this.maxReconnectAttempts = 3;
        this.messageHandlers = [];
        this.reconnectUrl = null;
    }

    connect(url) {
        if (this.ws) {
            this.disconnect();
        }

        console.log('🔌 Connecting to WebSocket:', url);
        this.reconnectUrl = url;
        this.ws = new WebSocket(url);

        this.ws.onopen = () => {
            console.log('✅ WebSocket connected');
            this.isConnected = true;
            this.reconnectAttempts = 0;
            this.updateStatus('connected');
        };

        this.ws.onmessage = (event) => {
            console.log('📨 WebSocket message:', event.data);
            try {
                const data = JSON.parse(event.data);
                this.handleMessage(data);
            } catch (e) {
                console.error('❌ Failed to parse WebSocket message:', e);
            }
        };

        this.ws.onerror = (error) => {
            console.error('❌ WebSocket error:', error);
            this.updateStatus('error');
        };

        this.ws.onclose = (event) => {
            console.log('🔌 WebSocket closed:', event.code, event.reason);
            this.isConnected = false;
            this.updateStatus('disconnected');

            // Auto-reconnect with exponential backoff
            if (this.reconnectAttempts < this.maxReconnectAttempts && this.reconnectUrl) {
                this.reconnectAttempts++;
                const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts - 1), 5000);
                console.log(`🔄 Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})...`);
                setTimeout(() => {
                    if (this.reconnectUrl) {
                        this.connect(this.reconnectUrl);
                    }
                }, delay);
            }
        };
    }

    disconnect() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
        this.isConnected = false;
        this.reconnectUrl = null;
        this.reconnectAttempts = 0;
        this.updateStatus('disconnected');
    }

    send(data) {
        if (this.ws && this.isConnected) {
            this.ws.send(JSON.stringify(data));
        } else {
            console.error('❌ WebSocket not connected');
        }
    }

    handleMessage(data) {
        // Check for device pairing requests
        if (data.type === 'pairing_required' || data.type === 'device_pairing_required') {
            this.showPairingNotification(data);
        }

        // Call all registered message handlers
        this.messageHandlers.forEach(handler => handler(data));
    }

    showPairingNotification(data) {
        const container = document.getElementById('pairing-notification');
        if (container) {
            container.classList.remove('hidden');
            container.dataset.requestId = data.requestId || data.request_id || '';
        }
    }

    updateStatus(status) {
        const statusEl = document.getElementById('ws-status');
        if (!statusEl) return;

        const statusConfig = {
            'connected': { text: '🟢 Connected', class: 'status-connected' },
            'disconnected': { text: '🔴 Disconnected', class: 'status-disconnected' },
            'error': { text: '🟡 Error', class: 'status-error' }
        };

        const config = statusConfig[status] || statusConfig.disconnected;
        statusEl.textContent = config.text;
        statusEl.className = `ws-status ${config.class}`;
    }

    onMessage(handler) {
        this.messageHandlers.push(handler);
    }
}

// Dashboard page logic
const Dashboard = {
    currentInstance: null,
    refreshTimer: null,
    isDeleting: false,
    wsManager: new WebSocketManager(),

    // Initialize dashboard
    init() {
        console.log('🚀 Dashboard initializing...');

        // Check authentication via session
        fetch('/me', {
            credentials: 'same-origin'  // Include cookies (session)
        })
            .then(response => {
                if (!response.ok) {
                    throw new Error('Not authenticated');
                }
                return response.json();
            })
            .then(data => {
                // Store user session
                Auth.session = data.user;

                // Display user email
                document.getElementById('user-email').textContent = data.user.email;

                // Setup event listeners
                this.setupEventListeners();

                // Load models list
                this.loadModels();

                // Load user's instance
                this.loadInstance();

                // Setup auto-refresh
                this.startAutoRefresh();
            })
            .catch(error => {
                console.error('❌ Authentication check failed:', error);
                this.showError('Not authenticated. Redirecting to login...');
                this.showEmptyState();
                const loginPath = window.location.pathname.startsWith('/prod') ? '/prod/login' : '/login';
                setTimeout(() => window.location.href = loginPath, 2000);
            });
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

        // Provider selector toggle
        document.querySelectorAll('.provider-option').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('.provider-option').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                // Show/hide API key input
                const apiKeyGroup = document.getElementById('siliconflow-apikey-group');
                if (btn.dataset.provider === 'siliconflow') {
                    apiKeyGroup.classList.remove('hidden');
                } else {
                    apiKeyGroup.classList.add('hidden');
                }
                // Repopulate model dropdown for the selected provider
                this.populateModelSelect(btn.dataset.provider);
            });
        });

        // API key show/hide toggle
        const toggleKeyBtn = document.getElementById('toggle-apikey-btn');
        if (toggleKeyBtn) {
            toggleKeyBtn.addEventListener('click', () => {
                const input = document.getElementById('siliconflow-apikey');
                if (input.type === 'password') {
                    input.type = 'text';
                    toggleKeyBtn.textContent = '🙈';
                } else {
                    input.type = 'password';
                    toggleKeyBtn.textContent = '👁️';
                }
            });
        }
    },

    // All models keyed by provider
    allModels: {},

    // Load available models and populate dropdown
    async loadModels() {
        try {
            const data = await API.getModels();
            if (!data.bedrock && !data.siliconflow) return;

            this.allModels = data;
            // Populate dropdown for the currently active provider
            const activeProvider = document.querySelector('.provider-option.active')?.dataset.provider || 'bedrock';
            this.populateModelSelect(activeProvider);
        } catch (error) {
            console.error('Failed to load models:', error);
        }
    },

    // Populate model dropdown for a given provider
    populateModelSelect(provider) {
        const select = document.getElementById('model-select');
        if (!select) return;

        const models = this.allModels[provider] || [];
        select.innerHTML = '';
        models.forEach(model => {
            const option = document.createElement('option');
            option.value = model.id;
            option.textContent = `${model.name}  —  ${model.provider_label}`;
            if (model.default) option.selected = true;
            select.appendChild(option);
        });
    },

    // Handle logout
    handleLogout() {
        this.stopAutoRefresh();
        Auth.logout();
        const loginPath = window.location.pathname.startsWith('/prod') ? '/prod/login' : '/login';
        window.location.href = loginPath;
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
            const msg = error.message || '';
            // Suppress "not found", auth errors — just show empty state
            const isExpected = msg.includes('404') || msg.includes('not found')
                || msg.includes('401') || msg.includes('403')
                || msg.includes('Not authenticated');
            if (!isExpected) {
                this.showError(`Failed to load instance: ${msg}`);
            }
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

        // Update provider badge
        const providerEl = document.getElementById('instance-provider');
        if (providerEl) {
            const llmProvider = instance.llm_provider || 'bedrock';
            if (llmProvider === 'siliconflow') {
                providerEl.innerHTML = '<span class="runtime-badge runtime-kata">🤖 SiliconFlow</span>';
            } else {
                providerEl.innerHTML = '<span class="runtime-badge runtime-runc">☁️ Bedrock</span>';
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

        // Update gateway endpoint — prioritize CloudFront HTTP URL
        const gatewayEl = document.getElementById('instance-gateway');

        // Priority 1: CloudFront HTTP URL (new production URL)
        if (instance.cloudfront_http_url) {
            gatewayEl.textContent = instance.cloudfront_http_url;
            document.getElementById('copy-gateway-btn').disabled = false;
        }
        // Priority 2: API Gateway URL (legacy fallback)
        else if (instance.api_gateway_url) {
            gatewayEl.textContent = instance.api_gateway_url;
            document.getElementById('copy-gateway-btn').disabled = false;
        }
        // Priority 3: Generating message (instead of kubectl command)
        else {
            gatewayEl.textContent = 'Generating endpoint...';
            document.getElementById('copy-gateway-btn').disabled = true;
        }

        // Update connect button based on ready_for_connect flag
        const connectBtn = document.getElementById('connect-btn');
        const approveDeviceBtn = document.getElementById('approve-device-btn');

        // Keep buttons disabled during delete
        if (this.isDeleting) {
            connectBtn.disabled = true;
            connectBtn.innerHTML = '<span>⏳</span> Deleting...';
            if (approveDeviceBtn) approveDeviceBtn.disabled = true;
        } else {
            const readyForConnect = instance.ready_for_connect === true;

            if (readyForConnect) {
                connectBtn.disabled = false;
                connectBtn.innerHTML = '<span>🔗</span> Connect to Gateway';
                // Enable Approve Device button when instance is running
                if (approveDeviceBtn) approveDeviceBtn.disabled = false;
            } else {
                connectBtn.disabled = true;
                // Show specific waiting message
                if (instance.status_message) {
                    connectBtn.innerHTML = `<span>⏳</span> ${instance.status_message}`;
                } else {
                    connectBtn.innerHTML = '<span>⏳</span> Starting...';
                }
                // Disable Approve Device while instance is not ready
                if (approveDeviceBtn) approveDeviceBtn.disabled = true;
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

        // Get selected provider
        const selectedProvider = document.querySelector('.provider-option.active')?.dataset.provider || 'bedrock';
        const providerLabel = selectedProvider === 'siliconflow' ? 'SiliconFlow' : 'Bedrock';

        // Get selected model
        let selectedModel = null;
        let modelLabel = '';
        const modelSelect = document.getElementById('model-select');
        if (modelSelect && modelSelect.value) {
            selectedModel = modelSelect.value;
            modelLabel = modelSelect.options[modelSelect.selectedIndex]?.textContent || selectedModel;
        }

        // Validate SiliconFlow API key
        let siliconflowApiKey = null;
        if (selectedProvider === 'siliconflow') {
            siliconflowApiKey = document.getElementById('siliconflow-apikey')?.value?.trim();
            if (!siliconflowApiKey) {
                this.showError('Please enter your SiliconFlow API key.');
                return;
            }
            if (!siliconflowApiKey.startsWith('sk-')) {
                this.showError('SiliconFlow API key should start with "sk-".');
                return;
            }
        }

        const modelInfo = selectedModel ? `\nModel: ${modelLabel}` : '';
        if (!confirm(`Create a new OpenClaw instance?\n\nProvider: ${providerLabel}${modelInfo}\nRuntime: ${runtimeLabel}\nStorage: ${storageLabel}\n\nThis may take a few minutes.`)) {
            return;
        }

        const createBtn = document.getElementById('create-instance-btn');
        createBtn.disabled = true;
        createBtn.innerHTML = '<span>⏳</span> Creating...';
        this.hideError();

        try {
            const result = await API.createInstance(selectedRuntime, selectedProvider, siliconflowApiKey, selectedModel);
            console.log('Instance created:', result);

            // Show success state
            createBtn.innerHTML = '<span>✓</span> Created';
            this.showSuccess('Instance created successfully! Loading...');

            // Refresh after a delay
            setTimeout(() => this.loadInstance(), 2000);
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

        // Set deleting state — disable buttons and show "Deleting" badge
        this.isDeleting = true;
        const connectBtn = document.getElementById('connect-btn');
        const deleteBtn = document.getElementById('delete-btn');
        connectBtn.disabled = true;
        connectBtn.innerHTML = '<span>⏳</span> Deleting...';
        deleteBtn.disabled = true;

        const statusEl = document.getElementById('instance-status');
        statusEl.textContent = 'Deleting';
        statusEl.className = 'status-badge status-warning';

        try {
            await API.deleteInstance(this.currentInstance.user_id);
            console.log('Instance deleted');

            this.isDeleting = false;
            this.showSuccess('Instance deleted successfully!');
            this.currentInstance = null;

            setTimeout(() => this.loadInstance(), 2000);
        } catch (error) {
            console.error('Failed to delete instance:', error);
            this.isDeleting = false;
            connectBtn.disabled = false;
            deleteBtn.disabled = false;
            this.showError(`Failed to delete instance: ${error.message}`);
            // Restore original status
            if (this.currentInstance) {
                this.showInstance(this.currentInstance);
            }
        }
    },

    // Handle connect to instance - open gateway in new tab
    async handleConnectInstance() {
        if (!this.currentInstance) {
            this.showError('No instance selected');
            return;
        }

        // Use CloudFront HTTP URL (for browser access)
        const gatewayUrl = this.currentInstance.cloudfront_http_url;

        if (!gatewayUrl) {
            this.showError('Gateway URL not available yet. Please wait for instance to be ready.');
            return;
        }

        try {
            // Open gateway in new tab
            window.open(gatewayUrl, '_blank');
            this.showSuccess('Opening gateway in new tab...');
        } catch (error) {
            console.error('Failed to open gateway:', error);
            this.showError(`Failed to open gateway: ${error.message}`);
        }
    },

    // Handle disconnect from instance
    handleDisconnectInstance() {
        this.wsManager.disconnect();

        // Hide WebSocket controls panel
        const wsControls = document.getElementById('ws-controls');
        if (wsControls) {
            wsControls.classList.add('hidden');
        }

        // Hide pairing notification if visible
        const pairingNotif = document.getElementById('pairing-notification');
        if (pairingNotif) {
            pairingNotif.classList.add('hidden');
        }

        this.showSuccess('Disconnected from gateway');
    },

    // Handle approve device (triggered by WebSocket pairing notification)
    async handleApproveDevice() {
        const notification = document.getElementById('pairing-notification');
        const requestId = notification?.dataset.requestId;

        if (!requestId || !this.currentInstance) {
            this.showError('No pending device pairing request');
            return;
        }

        try {
            this.hideError();
            const result = await API.approveDevice(
                this.currentInstance.user_id,
                requestId
            );

            if (result.success) {
                this.showSuccess('✅ Device approved successfully!');
                notification.classList.add('hidden');

                // Reconnect WebSocket after approval
                setTimeout(() => {
                    if (this.currentInstance && this.currentInstance.cloudfront_url) {
                        console.log('🔄 Reconnecting WebSocket after device approval...');
                        this.wsManager.connect(this.currentInstance.cloudfront_url);
                    }
                }, 1000);
            } else {
                this.showError('Failed to approve device');
            }
        } catch (error) {
            console.error('Failed to approve device:', error);
            this.showError(`Failed to approve device: ${error.message}`);
        }
    },

    // Handle approve device manually (auto-find pending request)
    async handleApproveDeviceManual() {
        if (!this.currentInstance) {
            this.showError('No instance selected');
            return;
        }

        const approveBtn = document.getElementById('approve-device-btn');
        const statusContainer = document.getElementById('device-approval-status');
        const statusMessage = document.getElementById('approval-status-message');

        try {
            this.hideError();

            // Set button to "Approving..." state
            approveBtn.disabled = true;
            approveBtn.innerHTML = '<span>⏳</span> Approving...';

            // Hide previous status
            if (statusContainer) {
                statusContainer.style.display = 'none';
            }

            // Call API with request_id=null, backend will auto-find pending request
            const result = await API.approveDevice(
                this.currentInstance.user_id,
                null  // request_id null triggers auto-find in backend
            );

            if (result.success) {
                // Success: Show approved button
                approveBtn.innerHTML = '<span>✓</span> Approved';
                approveBtn.classList.remove('btn-primary');
                approveBtn.classList.add('btn-success');
                // Keep button disabled - approved state

                // Show success message below gateway endpoint
                if (statusContainer && statusMessage) {
                    statusMessage.className = 'approval-status-message success';
                    statusMessage.innerHTML = '✅ Device approved successfully! You can now pair your devices.';
                    statusContainer.style.display = 'block';
                }

                // Reconnect WebSocket after approval
                if (this.wsManager.isConnected && this.currentInstance.cloudfront_url) {
                    setTimeout(() => {
                        console.log('🔄 Reconnecting WebSocket after device approval...');
                        this.wsManager.connect(this.currentInstance.cloudfront_url);
                    }, 1000);
                }
            } else {
                // Backend returned success=false, meaning no pending requests
                // Restore button to original state
                approveBtn.disabled = false;
                approveBtn.innerHTML = '<span>🔐</span> Approve Device';

                // Show warning message
                if (statusContainer && statusMessage) {
                    statusMessage.className = 'approval-status-message warning';
                    statusMessage.innerHTML = '⚠️ ' + (result.message || 'No pending device requests found');
                    statusContainer.style.display = 'block';
                }
            }
        } catch (error) {
            console.error('Failed to approve device:', error);

            // Restore button to original state
            approveBtn.disabled = false;
            approveBtn.innerHTML = '<span>❌</span> Approve Device';

            // Show error message
            if (statusContainer && statusMessage) {
                statusMessage.className = 'approval-status-message error';
                statusMessage.innerHTML = '❌ Failed to approve device: ' + error.message + ' (Click to retry)';
                statusContainer.style.display = 'block';
            }

            this.showError(`Failed to approve device: ${error.message}`);
        }
    },

    // Copy gateway endpoint to clipboard
    copyGatewayEndpoint() {
        const gatewayEl = document.getElementById('instance-gateway');
        const displayedText = gatewayEl ? gatewayEl.textContent : '';
        if (!displayedText || displayedText === 'Not available yet') {
            return;
        }

        navigator.clipboard.writeText(displayedText).then(() => {
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
