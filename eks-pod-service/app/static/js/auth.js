// Authentication module using amazon-cognito-identity-js
const Auth = {
    // Current user session
    session: null,
    userPool: null,

    // Initialize authentication
    init() {
        // Initialize Cognito User Pool
        if (!this.userPool) {
            const poolData = {
                UserPoolId: CONFIG.COGNITO.USER_POOL_ID,
                ClientId: CONFIG.COGNITO.CLIENT_ID
            };
            this.userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);
        }

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

    // Sign in with Cognito using SDK
    async signIn(email, password) {
        return new Promise((resolve, reject) => {
            try {
                const authenticationData = {
                    Username: email,
                    Password: password,
                };

                const authenticationDetails = new AmazonCognitoIdentity.AuthenticationDetails(authenticationData);

                const userData = {
                    Username: email,
                    Pool: this.userPool
                };

                const cognitoUser = new AmazonCognitoIdentity.CognitoUser(userData);

                cognitoUser.authenticateUser(authenticationDetails, {
                    onSuccess: (result) => {
                        console.log('✅ Authentication successful');

                        const idToken = result.getIdToken().getJwtToken();
                        const accessToken = result.getAccessToken().getJwtToken();
                        const refreshToken = result.getRefreshToken().getToken();

                        // Parse ID token to get user info
                        const idTokenPayload = this.parseJWT(idToken);

                        // Save session
                        this.session = {
                            email: idTokenPayload.email || email,
                            cognitoSub: idTokenPayload.sub,
                            idToken: idToken,
                            accessToken: accessToken,
                            refreshToken: refreshToken,
                            expiresAt: (() => {
                                const exp = result.getIdToken().getExpiration();
                                // Defensive check: if exp looks like milliseconds (> year 2030), don't multiply by 1000
                                const expMs = exp > 2000000000 ? exp : exp * 1000;
                                console.log('✅ Token expiration set:', new Date(expMs), '(', Math.floor((expMs - Date.now()) / 60000), 'minutes from now)');
                                return expMs;
                            })()
                        };

                        // Save to localStorage
                        localStorage.setItem('openclaw_session', JSON.stringify(this.session));

                        resolve(this.session);
                    },
                    onFailure: (err) => {
                        console.error('❌ Authentication failed:', err);
                        reject(new Error(err.message || 'Authentication failed'));
                    }
                });
            } catch (error) {
                console.error('Sign in error:', error);
                reject(error);
            }
        });
    },

    // Sign out
    logout() {
        this.session = null;
        localStorage.removeItem('openclaw_session');
    },

    // Check if token is still valid
    isTokenValid() {
        if (!this.session || !this.session.expiresAt) {
            console.log('❌ Token validation failed: No session or expiresAt');
            return false;
        }

        // Check if token has expired (with 1 minute buffer instead of 5)
        const threshold = Date.now() + 1 * 60 * 1000;  // 1 minute buffer
        const isValid = this.session.expiresAt > threshold;
        const minutesLeft = Math.floor((this.session.expiresAt - Date.now()) / 60000);

        console.log('Token validation:', {
            expiresAt: new Date(this.session.expiresAt).toISOString(),
            now: new Date().toISOString(),
            minutesLeft: minutesLeft,
            isValid: isValid
        });

        if (!isValid) {
            console.log('❌ Token expired or expiring soon (< 1 minute)');
        }

        return isValid;
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
