import { createContext, useCallback, useContext, useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react';

declare global {
  interface ImportMeta {
    readonly env: {
      readonly VITE_API_URL?: string;
    };
  }
}

const API = import.meta.env.VITE_API_URL || 'http://localhost:8000';

export type Account = {
  id: number;
  email: string;
  role: 'admin' | 'teacher' | 'student';
  teacher_id: number | null;
  student_id: number | null;
  csrf_token: string;
};

type AuthContextValue = {
  account: Account | null;
  csrfToken: string;
  checking: boolean;
  error: string;
  login: (email: string, password: string, role: Account['role']) => Promise<void>;
  logout: () => Promise<void>;
  updateSession: (account: Account) => void;
};

const AuthContext = createContext<AuthContextValue | null>(null);

async function responseError(response: Response): Promise<Error> {
  const body = await response.json().catch(() => ({}));
  const detail: unknown = body && typeof body === 'object' && 'detail' in body ? body.detail : undefined;
  if (typeof detail === 'string') return new Error(detail);
  if (Array.isArray(detail)) {
    const messages = detail.map(issue => {
      if (!issue || typeof issue !== 'object') return String(issue);
      const value = issue as { loc?: unknown[]; msg?: unknown };
      const location = value.loc?.filter((part): part is string | number => typeof part === 'string' || typeof part === 'number').join('.');
      return `${location ? `${location}: ` : ''}${typeof value.msg === 'string' ? value.msg : 'Invalid value'}`;
    });
    if (messages.length) return new Error(messages.join('; '));
  }
  return new Error(`Request failed (${response.status})`);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [account, setAccount] = useState<Account | null>(null);
  const [csrfToken, setCsrfToken] = useState('');
  const [checking, setChecking] = useState(true);
  const [error, setError] = useState('');
  const updateSession = useCallback((user: Account) => {
    setAccount(user);
    setCsrfToken(user.csrf_token);
  }, []);

  useEffect(() => {
    let active = true;
    fetch(`${API}/api/auth/me`, { credentials: 'include' })
      .then(async response => {
        if (response.status === 401) return null;
        if (!response.ok) throw await responseError(response);
        return response.json() as Promise<Account>;
      })
      .then(user => {
        if (!active || !user) return;
        setAccount(user);
        setCsrfToken(user.csrf_token);
      })
      .catch((reason: unknown) => {
        if (active) setError(reason instanceof Error ? reason.message : 'Could not verify the current session.');
      })
      .finally(() => {
        if (active) setChecking(false);
      });

    return () => {
      active = false;
    };
  }, []);

  const login = useCallback(async (email: string, password: string, role: Account['role']) => {
    setError('');
    const response = await fetch(`${API}/api/auth/login`, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, role }),
    });
    if (!response.ok) throw await responseError(response);
    const user = (await response.json()) as Account;
    updateSession(user);
  }, [updateSession]);

  const logout = useCallback(async () => {
    const response = await fetch(`${API}/api/auth/logout`, {
      method: 'POST',
      credentials: 'include',
      headers: { 'X-CSRF-Token': csrfToken },
    });
    if (!response.ok) throw await responseError(response);
    setAccount(null);
    setCsrfToken('');
  }, [csrfToken]);

  const value = useMemo(
    () => ({ account, csrfToken, checking, error, login, logout, updateSession }),
    [account, csrfToken, checking, error, login, logout, updateSession],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth must be used within AuthProvider.');
  return context;
}

export function AuthGate({ children }: { children: ReactNode }) {
  const { account, checking, error, login } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [role, setRole] = useState<Account['role']>('admin');
  const [submitting, setSubmitting] = useState(false);
  const [loginError, setLoginError] = useState('');

  async function submit(event: FormEvent) {
    event.preventDefault();
    setSubmitting(true);
    setLoginError('');
    try {
      await login(email, password, role);
      setPassword('');
    } catch (reason) {
      setLoginError(reason instanceof Error ? reason.message : 'Sign in failed.');
    } finally {
      setSubmitting(false);
    }
  }

  if (checking) return <main className="auth-page"><div className="auth-card">Checking your session…</div></main>;
  if (account) return <>{children}</>;

  return (
    <main className="auth-page">
      <form className="auth-card" onSubmit={submit}>
        <div className="auth-brand">edtech<span>.</span></div>
        <h1>Sign in</h1>
        <p>Choose your account type and sign in to continue.</p>
        {(loginError || error) && <div className="alert error" role="alert">{loginError || error}</div>}
        <label>Account type<select value={role} onChange={event => setRole(event.target.value as Account['role'])}><option value="admin">Administrator</option><option value="teacher">Teacher</option><option value="student">Student</option></select></label>
        <label>Email<input type="email" autoComplete="username" required value={email} onChange={event => setEmail(event.target.value)} /></label>
        <label>Password<input type="password" autoComplete="current-password" required value={password} onChange={event => setPassword(event.target.value)} /></label>
        <button className="btn primary" type="submit" disabled={submitting}>{submitting ? 'Signing in…' : 'Sign in'}</button>
      </form>
    </main>
  );
}
