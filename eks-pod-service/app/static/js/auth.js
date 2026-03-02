// Authentication module
const Auth = {
    // Current user session
    session: null,

    // Initialize authentication
    init() {
        // Check if user has a saved session
        const savedSession = localStorage.getItem('openclaw_session');
        if (savedSession) {
            try {
                this.session = JSON.parse(savedSession);
                // Verify token is still valid
                if (this.isTokenValid()) {
                    return true;
                } else {
                    this.logout();
                }
            } catch (e) {
                console.error('Failed to parse saved session:', e);
                this.logout();
            }
        }
        return false;
    },

    // Sign in with Cognito
    async signIn(email, password) {
        try {
            // Use AWS Cognito Identity Provider API
            const endpoint = `https://cognito-idp.${CONFIG.COGNITO.REGION}.amazonaws.com/`;

            const params = {
                AuthFlow: 'USER_PASSWORD_AUTH',
                ClientId: CONFIG.COGNITO.CLIENT_ID,
                AuthParameters: {
                    USERNAME: email,
                    PASSWORD: password
                }
            };

            const response = await fetch(endpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-amz-json-1.1',
                    'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth'
                },
                body: JSON.stringify(params)
            });

            if (!response.ok) {
                const error = await response.json();
                throw new Error(error.message || 'Authentication failed');
            }

            const data = await response.json();

            if (!data.AuthenticationResult) {
                throw new Error('No authentication result received');
            }

            // Save session
            this.session = {
                email: email,
                idToken: data.AuthenticationResult.IdToken,
                accessToken: data.AuthenticationResult.AccessToken,
                refreshToken: data.AuthenticationResult.RefreshToken,
                expiresAt: Date.now() + (data.AuthenticationResult.ExpiresIn * 1000)
            };

            // Parse ID token to get user info
            const idTokenPayload = this.parseJWT(this.session.idToken);
            this.session.cognitoSub = idTokenPayload.sub;
            this.session.email = idTokenPayload.email || email;

            // Save to localStorage
            localStorage.setItem('openclaw_session', JSON.stringify(this.session));

            return this.session;
        } catch (error) {
            console.error('Sign in error:', error);
            throw error;
        }
    },

    // Sign out
    logout() {
        this.session = null;
        localStorage.removeItem('openclaw_session');
    },

    // Check if token is still valid
    isTokenValid() {
        if (!this.session || !this.session.expiresAt) {
            return false;
        }
        // Check if token expires in next 5 minutes
        return this.session.expiresAt > (Date.now() + 5 * 60 * 1000);
    },

    // Get authorization header
    getAuthHeader() {
        if (!this.session || !this.session.idToken) {
            return {};
        }
        // Only send the JWT token - backend will verify and extract user info
        return {
            'Authorization': `Bearer ${this.session.idToken}`
        };
    },

    // Parse JWT token
    parseJWT(token) {
        try {
            const base64Url = token.split('.')[1];
            const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
            const jsonPayload = decodeURIComponent(
                atob(base64)
                    .split('')
                    .map(c => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
                    .join('')
            );
            return JSON.parse(jsonPayload);
        } catch (e) {
            console.error('Failed to parse JWT:', e);
            return null;
        }
    },

    // Get current user email
    getUserEmail() {
        return this.session ? this.session.email : null;
    }
};
