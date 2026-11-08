import { readFileSync } from 'node:fs';
import { captureCommand } from './lib/cli.mjs';
import { detail, fail, info, pass, redact, section, summarize } from './lib/output.mjs';

const SKIP_FILES = new Set(['package-lock.json']);

const PATTERNS = [
  {
    name: 'private key',
    pattern: /-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/,
  },
  {
    name: 'AWS access key',
    pattern: /\bAKIA[0-9A-Z]{16}\b/,
  },
  {
    name: 'GitHub token',
    pattern: /\b(?:ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,})\b/,
  },
  {
    name: 'Slack token',
    pattern: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
  },
  {
    name: 'generic API key',
    pattern: /\bsk-[A-Za-z0-9]{24,}\b/,
  },
  {
    name: 'JWT-like credential',
    pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
  },
  {
    name: 'service-role assignment',
    pattern: /SUPABASE_SERVICE_ROLE_KEY\s*=\s*["']?(?:eyJ|[A-Za-z0-9_-]{20,})/i,
  },
  {
    name: 'remote database credential',
    pattern:
      /postgres(?:ql)?:\/\/[^\s:@/]+:[^\s@/]+@(?!localhost\b|127\.0\.0\.1\b|\[::1\]\b)/i,
  },
];

function isPlaceholder(line, matched = '') {
  if (/(?:placeholder|redacted|your[-_]|<[^>]+>|xxx)/i.test(line)) return true;
  return /example/i.test(line) && matched.length < 24;
}

function listTrackedFiles() {
  const result = captureCommand(
    'git',
    ['ls-files', '--cached', '--others', '--exclude-standard'],
    { timeout: 30000 },
  );
  if (!result.ok) {
    throw new Error('Could not list tracked files with git.');
  }
  return result.stdout.split(/\r?\n/).filter(Boolean);
}

function main() {
  section('Secret scan');
  const files = listTrackedFiles();
  const findings = [];

  for (const file of files) {
    if (SKIP_FILES.has(file)) continue;
    let contents;
    try {
      contents = readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    if (contents.includes('\u0000')) continue;

    const lines = contents.split(/\r?\n/);
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      for (const rule of PATTERNS) {
        const match = line.match(rule.pattern);
        if (!match) continue;
        if (isPlaceholder(line, match[0])) continue;
        findings.push({
          file,
          line: index + 1,
          rule: rule.name,
          sample: redact(match[0]),
        });
      }
    }
  }

  if (findings.length > 0) {
    for (const finding of findings) {
      fail(`${finding.file}:${finding.line} possible ${finding.rule} (${finding.sample})`);
    }
    detail('Remove the credential, rotate it if real, and use local placeholders.');
    return summarize(['secret scan']);
  }

  pass(`Scanned ${files.length} tracked file(s); no credential patterns found.`);
  info('Generated test output is redacted at the source; do not print raw tokens.');
  return 0;
}

process.exit(main());
