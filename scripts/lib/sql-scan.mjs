/**
 * Lightweight SQL analysis for migration governance.
 *
 * This is intentionally conservative: it understands comments, quoted strings,
 * and dollar-quoted bodies well enough to distinguish real statements from text
 * that merely looks like one. It is not a full SQL parser.
 */

const UNTRUSTED_PRIVATE_ROLES = new Set(['anon', 'authenticated', 'public']);

const DESTRUCTIVE_RULES = [
  { rule: 'DROP TABLE', pattern: /\bdrop\s+table\b/gi },
  { rule: 'DROP COLUMN', pattern: /\bdrop\s+column\b/gi },
  { rule: 'DROP SCHEMA', pattern: /\bdrop\s+schema\b/gi },
  { rule: 'DROP TYPE', pattern: /\bdrop\s+type\b/gi },
  { rule: 'DELETE FROM', pattern: /\bdelete\s+from\b/gi },
  {
    rule: 'ALTER COLUMN TYPE',
    pattern:
      /\balter\s+table\b[\s\S]{0,300}?\balter\s+column\b[\s\S]{0,120}?\b(?:set\s+data\s+)?type\b/gi,
  },
];

function isEscapeString(sql, quoteIndex) {
  const prefix = sql[quoteIndex - 1];
  if (prefix !== 'E' && prefix !== 'e') return false;
  const beforePrefix = sql[quoteIndex - 2];
  return beforePrefix === undefined || !/[A-Za-z0-9_$]/.test(beforePrefix);
}

function findDollarTag(sql, index) {
  const match = sql.slice(index).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
  return match ? match[0] : null;
}

/**
 * Split SQL into statements without splitting on semicolons inside comments,
 * quoted strings/identifiers, or dollar-quoted function bodies.
 */
export function splitSqlStatements(sql) {
  const statements = [];
  let start = 0;
  let startLine = 1;
  let line = 1;
  let i = 0;

  const advance = (count = 1) => {
    for (let step = 0; step < count; step += 1) {
      if (sql[i] === '\n') line += 1;
      i += 1;
    }
  };

  while (i < sql.length) {
    const char = sql[i];
    const next = sql[i + 1];

    if (char === '-' && next === '-') {
      while (i < sql.length && sql[i] !== '\n') advance();
      continue;
    }

    if (char === '/' && next === '*') {
      let depth = 1;
      advance(2);
      while (i < sql.length && depth > 0) {
        if (sql[i] === '/' && sql[i + 1] === '*') {
          depth += 1;
          advance(2);
        } else if (sql[i] === '*' && sql[i + 1] === '/') {
          depth -= 1;
          advance(2);
        } else {
          advance();
        }
      }
      continue;
    }

    if (char === "'") {
      const escape = isEscapeString(sql, i);
      advance();
      while (i < sql.length) {
        if (escape && sql[i] === '\\') {
          advance(2);
          continue;
        }
        if (sql[i] === "'") {
          if (sql[i + 1] === "'") {
            advance(2);
            continue;
          }
          advance();
          break;
        }
        advance();
      }
      continue;
    }

    if (char === '"') {
      advance();
      while (i < sql.length) {
        if (sql[i] === '"') {
          if (sql[i + 1] === '"') {
            advance(2);
            continue;
          }
          advance();
          break;
        }
        advance();
      }
      continue;
    }

    if (char === '$') {
      const tag = findDollarTag(sql, i);
      if (tag) {
        advance(tag.length);
        while (i < sql.length && sql.slice(i, i + tag.length) !== tag) {
          advance();
        }
        if (i < sql.length) advance(tag.length);
        continue;
      }
    }

    if (char === ';') {
      statements.push({ text: sql.slice(start, i), startLine });
      advance();
      start = i;
      startLine = line;
      continue;
    }

    advance();
  }

  const tail = sql.slice(start);
  if (tail.trim().length > 0) {
    statements.push({ text: tail, startLine });
  }

  return statements;
}

function collectMaskRanges(sql) {
  const ranges = [];
  let i = 0;

  while (i < sql.length) {
    const char = sql[i];
    const next = sql[i + 1];

    if (char === '-' && next === '-') {
      const start = i;
      while (i < sql.length && sql[i] !== '\n') i += 1;
      ranges.push([start, i]);
      continue;
    }

    if (char === '/' && next === '*') {
      const start = i;
      let depth = 1;
      i += 2;
      while (i < sql.length && depth > 0) {
        if (sql[i] === '/' && sql[i + 1] === '*') {
          depth += 1;
          i += 2;
        } else if (sql[i] === '*' && sql[i + 1] === '/') {
          depth -= 1;
          i += 2;
        } else {
          i += 1;
        }
      }
      ranges.push([start, i]);
      continue;
    }

    if (char === "'") {
      const start = i;
      const escape = isEscapeString(sql, i);
      i += 1;
      while (i < sql.length) {
        if (escape && sql[i] === '\\') {
          i += 2;
          continue;
        }
        if (sql[i] === "'") {
          if (sql[i + 1] === "'") {
            i += 2;
            continue;
          }
          i += 1;
          break;
        }
        i += 1;
      }
      ranges.push([start, i]);
      continue;
    }

    if (char === '"') {
      i += 1;
      while (i < sql.length) {
        if (sql[i] === '"') {
          if (sql[i + 1] === '"') {
            i += 2;
            continue;
          }
          i += 1;
          break;
        }
        i += 1;
      }
      continue;
    }

    if (char === '$') {
      const tag = findDollarTag(sql, i);
      if (tag) {
        // Mask only the delimiter; keep the body visible so real statements
        // inside function/DO bodies are still inspected.
        ranges.push([i, i + tag.length]);
        i += tag.length;
        continue;
      }
    }

    i += 1;
  }

  return ranges;
}

/**
 * Replace comments, single-quoted strings, and dollar-quote delimiters with
 * spaces while preserving newlines and source length.
 */
export function maskSqlLiterals(sql) {
  const output = [...sql];
  for (const [start, end] of collectMaskRanges(sql)) {
    for (let index = start; index < end; index += 1) {
      if (output[index] !== '\n') output[index] = ' ';
    }
  }
  return output.join('');
}

export function extractStringLiterals(sql) {
  const literals = [];
  let i = 0;

  while (i < sql.length) {
    const char = sql[i];
    const next = sql[i + 1];

    if (char === '-' && next === '-') {
      while (i < sql.length && sql[i] !== '\n') i += 1;
      continue;
    }

    if (char === '/' && next === '*') {
      let depth = 1;
      i += 2;
      while (i < sql.length && depth > 0) {
        if (sql[i] === '/' && sql[i + 1] === '*') {
          depth += 1;
          i += 2;
        } else if (sql[i] === '*' && sql[i + 1] === '/') {
          depth -= 1;
          i += 2;
        } else {
          i += 1;
        }
      }
      continue;
    }

    if (char === '"') {
      i += 1;
      while (i < sql.length) {
        if (sql[i] === '"') {
          if (sql[i + 1] === '"') {
            i += 2;
            continue;
          }
          i += 1;
          break;
        }
        i += 1;
      }
      continue;
    }

    if (char === "'") {
      const escape = isEscapeString(sql, i);
      const contentStart = i + 1;
      i += 1;
      let value = '';
      while (i < sql.length) {
        if (escape && sql[i] === '\\') {
          value += sql[i] + (sql[i + 1] ?? '');
          i += 2;
          continue;
        }
        if (sql[i] === "'") {
          if (sql[i + 1] === "'") {
            value += "'";
            i += 2;
            continue;
          }
          i += 1;
          break;
        }
        value += sql[i];
        i += 1;
      }
      literals.push({ value, index: contentStart });
      continue;
    }

    if (char === '$') {
      const tag = findDollarTag(sql, i);
      if (tag) {
        i += tag.length;
        continue;
      }
    }

    i += 1;
  }

  return literals;
}

function lineForIndex(sql, index) {
  let line = 1;
  for (let i = 0; i < index && i < sql.length; i += 1) {
    if (sql[i] === '\n') line += 1;
  }
  return line;
}

function normalizeIdentifier(value) {
  const trimmed = value.trim();
  const unquoted =
    trimmed.startsWith('"') && trimmed.endsWith('"')
      ? trimmed.slice(1, -1).replaceAll('""', '"')
      : trimmed;
  return unquoted.toLowerCase();
}

function referencesPrivateSchema(sql) {
  return (
    /(?:"private"|\bprivate\b)\s*\./i.test(sql) ||
    /\b(?:in|on)\s+schema\s+(?:"private"|\bprivate\b)/i.test(sql)
  );
}

function extractGrantedRoles(sql) {
  const matches = [...sql.matchAll(/\bto\b/gi)];
  if (matches.length === 0) return [];

  const lastTo = matches[matches.length - 1];
  let roleSection = sql.slice(lastTo.index + lastTo[0].length);
  roleSection = roleSection.split(/;|\bwith\s+grant\s+option\b|\bgranted\s+by\b/i)[0];

  return roleSection
    .split(',')
    .map((role) => normalizeIdentifier(role.trim().split(/\s+/)[0] ?? ''))
    .filter(Boolean);
}

function analyzeGrantSql(sql) {
  if (!referencesPrivateSchema(sql)) return [];

  const roles = extractGrantedRoles(sql);
  const untrusted = roles.filter((role) => UNTRUSTED_PRIVATE_ROLES.has(role));
  if (untrusted.length === 0) return [];

  return [
    {
      rule: 'PRIVATE GRANT',
      message: `granting private-schema objects to ${untrusted.join(', ')} is not permitted`,
    },
  ];
}

function isGrantLike(sql) {
  return /^\s*(?:grant|alter\s+default\s+privileges)\b/i.test(sql);
}

export function findPrivateGrantViolations(sql) {
  const findings = [];
  for (const statement of splitSqlStatements(sql)) {
    const code = maskSqlLiterals(statement.text);

    if (isGrantLike(code)) {
      for (const finding of analyzeGrantSql(code)) {
        findings.push({
          ...finding,
          line: statement.startLine,
        });
      }
    }

    for (const literal of extractStringLiterals(statement.text)) {
      const content = literal.value.trim();
      if (!isGrantLike(content)) continue;
      for (const finding of analyzeGrantSql(content)) {
        findings.push({
          ...finding,
          line: statement.startLine + lineForIndex(statement.text, literal.index) - 1,
        });
      }
    }
  }
  return findings;
}

function isTriggerDefinition(sql) {
  return /^\s*create\s+(?:or\s+replace\s+)?(?:constraint\s+)?trigger\b/i.test(sql);
}

function findKeywordMatches(pattern, sql, rule) {
  const findings = [];
  for (const match of sql.matchAll(pattern)) {
    findings.push({
      rule,
      line: lineForIndex(sql, match.index ?? 0),
    });
  }
  return findings;
}

export function findDestructiveStatements(sql) {
  const findings = [];

  for (const statement of splitSqlStatements(sql)) {
    const code = maskSqlLiterals(statement.text);
    const triggerDefinition = isTriggerDefinition(code);

    if (!triggerDefinition) {
      for (const finding of findKeywordMatches(/\btruncate\b/gi, code, 'TRUNCATE')) {
        findings.push({ ...finding, line: statement.startLine + finding.line - 1 });
      }
    }

    for (const rule of DESTRUCTIVE_RULES) {
      for (const finding of findKeywordMatches(rule.pattern, code, rule.rule)) {
        findings.push({ ...finding, line: statement.startLine + finding.line - 1 });
      }
    }

    // Dynamic SQL that clearly starts with a destructive statement must still
    // be caught, while prose comments that merely mention TRUNCATE are not.
    for (const literal of extractStringLiterals(statement.text)) {
      const content = literal.value.trim();
      if (content.length === 0) continue;

      const dynamicDestructive =
        /(?:^|;)\s*(?:truncate\b|drop\s+(?:table|column|schema|type)\b|delete\s+from\b|alter\s+table\b)/i;
      if (!dynamicDestructive.test(content)) continue;

      if (!isTriggerDefinition(content)) {
        for (const match of content.matchAll(/\btruncate\b/gi)) {
          findings.push({
            rule: 'DYNAMIC TRUNCATE',
            line:
              statement.startLine +
              lineForIndex(statement.text, literal.index) +
              lineForIndex(content, match.index ?? 0) -
              1,
          });
        }
      }
      for (const rule of DESTRUCTIVE_RULES) {
        for (const match of content.matchAll(rule.pattern)) {
          findings.push({
            rule: `DYNAMIC ${rule.rule}`,
            line:
              statement.startLine +
              lineForIndex(statement.text, literal.index) +
              lineForIndex(content, match.index ?? 0) -
              1,
          });
        }
      }
    }
  }

  return dedupeFindings(findings);
}

export function findSecurityIssues(sql) {
  const findings = [];

  for (const statement of splitSqlStatements(sql)) {
    const code = maskSqlLiterals(statement.text);

    if (/\bdisable\s+row\s+level\s+security\b/i.test(code)) {
      findings.push({
        rule: 'DISABLE RLS',
        line: statement.startLine,
      });
    }

    if (
      /\bsecurity\s+definer\b/i.test(code) &&
      !/\bset\s+search_path\b/i.test(code)
    ) {
      findings.push({
        rule: 'SECURITY DEFINER',
        line: statement.startLine,
      });
    }
  }

  for (const finding of findPrivateGrantViolations(sql)) {
    findings.push(finding);
  }

  return dedupeFindings(findings);
}

export function analyzeSql(sql) {
  return {
    destructive: findDestructiveStatements(sql),
    security: findSecurityIssues(sql),
  };
}

function dedupeFindings(findings) {
  const seen = new Set();
  return findings.filter((finding) => {
    const key = `${finding.rule}:${finding.line}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
