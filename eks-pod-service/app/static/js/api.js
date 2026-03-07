// API module for backend communication
const API = {
    // Get base URL
    getBaseURL() {
        return CONFIG.API.USE_GATEWAY ? CONFIG.API.GATEWAY_ENDPOINT : CONFIG.API.BASE_URL;
    },

    // Make API request
    async request(endpoint, options = {}) {
        const url = `${this.getBaseURL()}${endpoint}`;

        const headers = {
            'Content-Type': 'application/json',
            ...Auth.getAuthHeader(),
            ...options.headers
        };

        const config = {
            ...options,
            headers
        };

        // Debug logging
        console.log('🔍 API Request:', {
            endpoint,
            url,
            method: config.method || 'GET',
            hasAuthHeader: !!headers.Authorization,
            authHeaderPreview: headers.Authorization ? headers.Authorization.substring(0, 30) + '...' : '❌ MISSING'
        });

        try {
            const response = await fetch(url, config);

            // Handle different response types
            const contentType = response.headers.get('content-type');
            let data;

            if (contentType && contentType.includes('application/json')) {
                data = await response.json();
            } else {
                data = await response.text();
            }

            if (!response.ok) {
                // TEMPORARY: Disable auto-redirect on 401 for debugging
                if (response.status === 401) {
                    console.error('❌ 401 Unauthorized:', {
                        endpoint,
                        headers,
                        response: data
                    });
                    // Auth.logout();
                    // const loginPath = window.location.pathname.startsWith('/prod') ? '/prod/login' : '/login';
                    // window.location.href = loginPath;
                    // return;
                }
                throw new Error(data.error || data.message || `HTTP ${response.status}`);
            }

            return data;
        } catch (error) {
            console.error(`API request failed: ${endpoint}`, error);
            throw error;
        }
    },

    // Health check
    async health() {
        return this.request('/health');
    },

    // Get current user's instance status
    async getMyInstance() {
        try {
            // Calculate user_id from email (same as backend)
            const email = Auth.getUserEmail();
            if (!email) {
                throw new Error('Not authenticated');
            }

            const userId = await this.calculateUserId(email);
            return this.request(`/status/${userId}`);
        } catch (error) {
            // If instance doesn't exist or auth expired, return null instead of throwing
            if (error.message.includes('404') || error.message.includes('not found')
                || error.message.includes('401') || error.message.includes('403')) {
                return null;
            }
            throw error;
        }
    },

    // Create new instance
    async createInstance(runtimeMode = 'runc', provider = 'bedrock', siliconflowApiKey = null) {
        const config = {};
        if (runtimeMode === 'kata-qemu') {
            config.runtime_class = 'kata-qemu';
            config.node_selector = { 'workload-type': 'kata' };
            config.tolerations = [{
                key: 'kata-dedicated',
                operator: 'Exists',
                effect: 'NoSchedule'
            }];
            config.storage_class = 'gp3';
        } else {
            config.storage_class = 'efs-sc';
        }
        const body = { config, provider };
        if (provider === 'siliconflow' && siliconflowApiKey) {
            body.siliconflow_api_key = siliconflowApiKey;
        }
        return this.request('/provision', {
            method: 'POST',
            body: JSON.stringify(body)
        });
    },

    // Delete instance
    async deleteInstance(userId) {
        return this.request(`/delete/${userId}`, {
            method: 'DELETE'
        });
    },

    // Calculate user_id from email (SHA256, first 8 chars)
    async calculateUserId(email) {
        const normalizedEmail = email.toLowerCase();
        const encoder = new TextEncoder();
        const data = encoder.encode(normalizedEmail);
        const hashBuffer = await crypto.subtle.digest('SHA-256', data);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
        return hashHex.substring(0, 8);
    },

    // Get instance gateway URL
    getGatewayURL(instance) {
        if (!instance || !instance.gateway_endpoint) {
            return null;
        }
        // gateway_endpoint format: "openclaw-{user_id}.openclaw.svc.cluster.local:18789"
        // For external access, we need to use the service endpoint
        // In production, this would go through an ingress
        return instance.gateway_endpoint;
    },

    // Open instance gateway in new window
    async openInstance(instance) {
        if (!instance) {
            throw new Error('Invalid instance');
        }

        // Initialize portForwardCmd variable outside the if/else
        let portForwardCmd = null;

        // Use API Gateway URL if available, otherwise show port-forward instructions
        if (instance.api_gateway_url) {
            // Open API Gateway URL in new tab (already authenticated via JWT)
            window.open(instance.api_gateway_url, '_blank');
        } else {
            // Fallback: show port-forward instructions
            const userId = instance.user_id;
            portForwardCmd = `kubectl port-forward -n openclaw-${userId} svc/openclaw-${userId} 18789:18789`;
            alert(`Instance Gateway Endpoint:\n\n${instance.gateway_endpoint}\n\nNote: API Gateway route not configured. Use port-forwarding:\n\n${portForwardCmd}\n\nThen open: http://localhost:18789/`);
        }

        if (portForwardCmd) {
            console.log('Port-forward command:', portForwardCmd);
        }

        return {
            endpoint: instance.gateway_endpoint,
            portForwardCommand: portForwardCmd
        };
    },

    // Approve device pairing request
    async approveDevice(userId, requestId) {
        return this.request('/api/devices/approve', {
            method: 'POST',
            body: JSON.stringify({
                user_id: userId,
                request_id: requestId
            })
        });
    },

    // List devices for user
    async listDevices(userId) {
        return this.request(`/api/devices/list?user_id=${userId || ''}`);
    }
};
