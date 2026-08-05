// Turn the per-language JSON into one table, sorted by workload and time.
import { readFileSync } from 'node:fs';

const [path, iterations] = process.argv.slice(2);
const results = readFileSync(path, 'utf8')
  .split('\n')
  .filter((line) => line.trim().startsWith('['))
  .flatMap((line) => JSON.parse(line));

const order = ['simple', 'unnamed', 'cached', 'rows_1000', 'rows_5000', 'wide_row', 'insert', 'concurrent'];
const pad = (value, width, right = false) =>
  right ? String(value).padStart(width) : String(value).padEnd(width);
const number = (value) => (value === undefined || value === null ? '-' : Math.round(value));

console.log(`\nminato benchmark, ${iterations} iterations\n`);
console.log(
  pad('workload', 12) + pad('client', 16) + pad('mean us', 10, true) +
  pad('median', 10, true) + pad('p99', 10, true) + pad('ops/s', 12, true),
);
console.log('-'.repeat(70));

for (const workload of order) {
  const rows = results
    .filter((r) => r.workload === workload)
    .sort((a, b) => (a.mean ?? Infinity) - (b.mean ?? Infinity));
  for (const row of rows) {
    console.log(
      pad(workload, 12) + pad(row.client, 16) + pad(number(row.mean), 10, true) +
      pad(number(row.median), 10, true) + pad(number(row.p99), 10, true) +
      pad(number(row.ops), 12, true),
    );
  }
  if (rows.length) console.log('');
}
