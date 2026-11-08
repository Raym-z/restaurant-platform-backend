const useColor = Boolean(process.stdout.isTTY) && process.env.NO_COLOR === undefined;

const ansi = (code) => (value) => (useColor ? `\u001b[${code}m${value}\u001b[0m` : value);

export const bold = ansi('1');
export const dim = ansi('2');
export const red = ansi('31');
export const green = ansi('32');
export const yellow = ansi('33');
export const blue = ansi('34');
export const cyan = ansi('36');

export function section(title) {
  console.log(`\n${bold(cyan(title))}`);
}

export function info(message) {
  console.log(`${blue('info')}  ${message}`);
}

export function pass(message) {
  console.log(`${green('pass')}  ${message}`);
}

export function warn(message) {
  console.log(`${yellow('warn')}  ${message}`);
}

export function fail(message) {
  console.error(`${red('fail')}  ${message}`);
}

export function detail(message) {
  console.log(`      ${dim(message)}`);
}

export function summarize(failures, warnings = []) {
  console.log('');
  if (warnings.length > 0) {
    warn(`${warnings.length} warning(s).`);
  }
  if (failures.length === 0) {
    pass('All checks passed.');
    return 0;
  }
  fail(`${failures.length} check(s) failed:`);
  for (const failure of failures) {
    console.error(`      - ${failure}`);
  }
  return 1;
}

export function redact(value) {
  if (!value) return '';
  if (value.length <= 10) return '<redacted>';
  return `${value.slice(0, 6)}…<redacted>`;
}
