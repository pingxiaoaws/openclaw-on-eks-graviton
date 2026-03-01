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
            // If instance doesn't exist, return null instead of throwing
            if (error.message.includes('404') || error.message.includes('not found')) {
                return null;
            }
            throw error;
        }
    },

    // Create new instance
    async createInstance() {
        return this.request('/provision', {
            method: 'POST',
            body: JSON.stringify({})
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

        // Get gateway token
        const userId = instance.user_id;

        // In a real implementation, you would:
        // 1. Get the gateway token from Kubernetes secret
        // 2. Open a proxy connection or set up port-forward
        // 3. Open the gateway UI in a new tab

        // For now, we'll show the gateway endpoint
        alert(`Instance Gateway Endpoint:\n\n${instance.gateway_endpoint}\n\nNote: You need to set up port-forwarding or ingress to access this endpoint from your browser.`);

        // Example kubectl command
        const portForwardCmd = `kubectl port-forward -n openclaw svc/openclaw-${userId} 18789:18789`;
        console.log('Port-forward command:', portForwardCmd);

        return {
            endpoint: instance.gateway_endpoint,
            portForwardCommand: portForwardCmd
        };
    }
};
