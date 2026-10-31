import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { AuthGate, AuthProvider } from './auth';
import './auth.css';
import './style.css';

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <AuthProvider>
      <AuthGate>
        <App />
      </AuthGate>
    </AuthProvider>
  </React.StrictMode>,
);