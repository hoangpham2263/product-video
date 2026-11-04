'use strict';

// Read-only app-server requests: no thread, model turn, credit reset or purchase.
const { spawn, execFile } = require('node:child_process');
const { existsSync } = require('node:fs');
const path = require('node:path');

function resolveCommand(cliPath) {
  if (/\.(ps1|cmd)$/i.test(cliPath)) {
    const candidates = [
      path.join(path.dirname(cliPath), 'node_modules', '@openai', 'codex', 'bin', 'codex.js'),
      path.resolve(path.dirname(cliPath), '..', '@openai', 'codex', 'bin', 'codex.js')
    ];
    const script = candidates.find(existsSync);
    if (!script) throw new Error('unsupported-launcher');
    return { file: process.execPath, args: [script, 'app-server', '--listen', 'stdio://'] };
  }
  return { file: cliPath, args: ['app-server', '--listen', 'stdio://'] };
}

function readQuota(command, timeoutMs = 12000) {
  return new Promise(resolve => {
    let child;
    let finished = false;
    let buffer = '';
    let phase = 'initialize';
    let timer;
    function finish(result) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve(result);
      if (!child) return;
      child.stdin.end();
      // EOF normally stops app-server. Bound shutdown of the launcher and its children.
      const stop = setTimeout(() => {
        if (child.exitCode !== null) return;
        if (process.platform === 'win32') {
          execFile('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }, () => {});
        } else { child.kill('SIGKILL'); }
      }, 800);
      child.once('exit', () => clearTimeout(stop));
    }
    function send(message) {
      child.stdin.write(JSON.stringify(message) + '\n');
    }
    try {
      child = spawn(command.file, command.args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
      child.on('error', () => finish({ available: false, reason: 'unavailable' }));
      child.stdin.on('error', () => finish({ available: false, reason: 'unavailable' }));
      child.stderr.resume(); // Never forward diagnostics, account identifiers or credentials.
      child.on('exit', () => finish({ available: false, reason: 'unavailable' }));
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => {
        if (finished) return;
        buffer += chunk;
        if (buffer.length > 2 * 1024 * 1024) return finish({ available: false, reason: 'invalid-response' });
        let newline;
        while (!finished && (newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          let message;
          try { message = JSON.parse(line); } catch { continue; }
          if (message.id === 1 && phase === 'initialize') {
            if (message.error || !message.result) return finish({ available: false, reason: 'unsupported' });
            phase = 'quota';
            send({ method: 'initialized', params: {} });
            send({ id: 2, method: 'account/rateLimits/read' });
          } else if (message.id === 2 && phase === 'quota') {
            // A 401 means the saved sign-in is no longer accepted (expired or revoked); only that is told apart.
            if (message.error) return finish({ available: false, reason: /\b401\b|unauthorized|sign(ing)? in again/i.test(String(message.error.message || '')) ? 'auth' : 'unavailable' });
            if (!message.result) return finish({ available: false, reason: 'unavailable' });
            finish({ available: true, data: message.result });
          }
        }
      });
      timer = setTimeout(() => finish({ available: false, reason: 'timeout' }), timeoutMs);
      send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'tools_hub_product_review', title: 'Product Review', version: '1.0.0' } } });
    } catch { finish({ available: false, reason: 'unavailable' }); }
  });
}

module.exports = { readQuota, resolveCommand };
if (require.main === module) {
  const cliPath = process.argv[2];
  if (!cliPath) {
    process.stdout.write(JSON.stringify({ available: false, reason: 'unavailable' }) + '\n');
  } else {
    let command;
    try { command = resolveCommand(cliPath); } catch { command = null; }
    if (!command) process.stdout.write(JSON.stringify({ available: false, reason: 'unsupported' }) + '\n');
    else readQuota(command).then(result => process.stdout.write(JSON.stringify(result) + '\n'));
  }
}
