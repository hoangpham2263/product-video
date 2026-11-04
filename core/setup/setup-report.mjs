import { execFile } from 'node:child_process';
import { mkdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';

const required = ['node', 'browser', 'grok'];
export function parseSetupReport(stdout) {
  const report = JSON.parse(String(stdout).replace(/^\uFEFF/, '').trim());
  if (!Array.isArray(report.Steps) || required.some(id => !report.Steps.some(s => s.Id === id))) throw new Error('Incomplete setup report');
  if (report.Steps.some(s => !['ok', 'warn', 'wait', 'fail'].includes(s.State))) throw new Error('Invalid setup state');
  return report;
}

// Concurrent menu/dialog/windows share one read-only child. A subsequent check always reads fresh state.
export function createSetupReader({ hubRoot, pwsh, args, env, execute = execFile, timeout = 45000 }) {
  let pending;
  return function readSetup() {
    if (pending) return pending;
    pending = new Promise(resolve => {
      execute(pwsh, args, { cwd: hubRoot, env, timeout, windowsHide: true, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
        try {
          // A failed readiness check can return exit 1 with a complete and valid report.
          resolve({ status: 200, report: parseSetupReport(stdout) });
        } catch {
          const timedOut = Boolean(err?.killed || err?.code === 'ETIMEDOUT');
          try {
            const logs = join(hubRoot, 'workspace', 'logs');
            mkdirSync(logs, { recursive: true });
            appendFileSync(join(logs, 'setup-api-errors.log'), `${new Date().toISOString()} code=${err?.code ?? 'invalid-json'} timeout=${timedOut} stdoutBytes=${Buffer.byteLength(String(stdout || ''))}\n${String(stderr || '').slice(0, 4000)}\n`);
          } catch {}
          resolve({ status: timedOut ? 504 : 500, report: {
            error: timedOut ? 'Kiểm tra cấu hình quá thời gian. Bấm Kiểm tra lại.' : 'Không đọc được kết quả kiểm tra. Bấm Kiểm tra lại.',
            code: timedOut ? 'SETUP_TIMEOUT' : 'SETUP_INVALID_REPORT',
          } });
        }
      });
    }).finally(() => { pending = null; });
    return pending;
  };
}
