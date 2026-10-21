#!/usr/bin/env bash
# Create a throwaway TypeScript repo for trying/testing revuey.
#   scripts/make-fixture.sh /tmp/revuey-fixture
# Produces branch `main` and a checked-out branch `feature/cart` with added, deleted, modified,
# renamed and binary files, plus cross-file calls (so `gd` has somewhere to go).
# No npm install needed: plain .ts files with relative imports work with typescript-language-server.
set -euo pipefail

dest=${1:?usage: make-fixture.sh <dir>}
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
  echo "refusing to overwrite non-empty $dest" >&2
  exit 1
fi
mkdir -p "$dest"
cd "$dest"

# Fixed identity and dates so commit hashes are reproducible (screenshot tests show them).
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
g() { git -c user.name=revuey -c user.email=revuey@example.com -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

g init -q -b main
mkdir -p src/utils src/components assets

cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "preserve",
    "strict": true,
    "noEmit": true
  },
  "include": ["src"]
}
EOF

# Minimal JSX typing so .tsx type-checks without installing React.
cat > src/jsx.d.ts <<'EOF'
declare namespace JSX {
  interface IntrinsicElements {
    [name: string]: Record<string, unknown>;
  }
}
EOF

cat > src/math.ts <<'EOF'
/** Add two numbers. */
export function add(a: number, b: number): number {
  return a + b;
}

/** Multiply two numbers. */
export function multiply(a: number, b: number): number {
  let result = 0;
  for (let i = 0; i < b; i++) {
    result = add(result, a);
  }
  return result;
}

export const PI_ISH = 3.14;

export function circleArea(r: number): number {
  return multiply(PI_ISH, r * r);
}
EOF

cat > src/format.ts <<'EOF'
export interface FormatOptions {
  currency: string;
  decimals: number;
}

const defaults: FormatOptions = { currency: "USD", decimals: 2 };

/** Format a number as a currency string. */
export function formatCurrency(value: number, options: Partial<FormatOptions> = {}): string {
  const opts = { ...defaults, ...options };
  return `${opts.currency} ${value.toFixed(opts.decimals)}`;
}

export function formatPercent(value: number): string {
  return `${Math.round(value * 100)}%`;
}
EOF

cat > src/utils/strings.ts <<'EOF'
export function capitalize(s: string): string {
  if (s.length === 0) return s;
  return s[0].toUpperCase() + s.slice(1);
}

export function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

export function slugify(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}
EOF

cat > src/legacy.ts <<'EOF'
// Old helpers kept for backwards compatibility.
export function oldTotal(prices: number[]): number {
  var t = 0;
  for (var i = 0; i < prices.length; i++) t += prices[i];
  return t;
}
EOF

cat > src/index.ts <<'EOF'
import { add, circleArea } from "./math";
import { formatCurrency } from "./format";
import { capitalize } from "./utils/strings";
import { oldTotal } from "./legacy";

export function main(): void {
  const total = oldTotal([1, 2, 3]);
  console.log(capitalize("total"), formatCurrency(total));
  console.log("area", circleArea(2));
  console.log("sum", add(2, 3));
}

main();
EOF

printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01' > assets/logo.png
printf '# Fixture shop\n\nA tiny TypeScript project used to try revuey.\n' > README.md

g add -A
g commit -q -m "Initial shop"

g checkout -q -b feature/cart

# --- modify math.ts: new function, changed implementation ------------------
cat > src/math.ts <<'EOF'
/** Add two numbers. */
export function add(a: number, b: number): number {
  return a + b;
}

/** Subtract b from a. */
export function subtract(a: number, b: number): number {
  return a - b;
}

/** Multiply two numbers. */
export function multiply(a: number, b: number): number {
  return a * b;
}

/** Sum a list of numbers. */
export function sum(values: readonly number[]): number {
  return values.reduce((acc, v) => add(acc, v), 0);
}

export const PI_ISH = Math.PI;

export function circleArea(radius: number): number {
  return multiply(PI_ISH, radius * radius);
}
EOF

# --- rename utils/strings.ts -> text.ts with a small change ----------------
mkdir -p src
git mv src/utils/strings.ts src/text.ts
cat > src/text.ts <<'EOF'
export function capitalize(s: string): string {
  if (s.length === 0) return s;
  return s[0].toUpperCase() + s.slice(1);
}

export function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

export function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}
EOF

# --- delete legacy.ts --------------------------------------------------------
git rm -q src/legacy.ts

# --- new cart.ts with cross-file calls --------------------------------------
cat > src/cart.ts <<'EOF'
import { multiply, sum } from "./math";
import { formatCurrency } from "./format";
import { capitalize } from "./text";

export interface LineItem {
  name: string;
  price: number;
  quantity: number;
}

export class Cart {
  private items: LineItem[] = [];

  addItem(item: LineItem): this {
    this.items.push(item);
    return this;
  }

  total(): number {
    return sum(this.items.map((i) => multiply(i.price, i.quantity)));
  }

  describe(): string {
    const names = this.items.map((i) => capitalize(i.name)).join(", ");
    return `${names}: ${formatCurrency(this.total())}`;
  }
}
EOF

# --- tsx component ------------------------------------------------------------
cat > src/components/Total.tsx <<'EOF'
import { formatCurrency } from "../format";

export function Total(props: { amount: number }) {
  return <strong className="total">{formatCurrency(props.amount)}</strong>;
}
EOF

# --- modify index.ts ------------------------------------------------------------
cat > src/index.ts <<'EOF'
import { add, circleArea, subtract } from "./math";
import { formatCurrency } from "./format";
import { capitalize } from "./text";
import { Cart } from "./cart";

export function main(): void {
  const cart = new Cart()
    .addItem({ name: "apple", price: 0.5, quantity: 6 })
    .addItem({ name: "pear", price: 0.75, quantity: 2 });
  console.log(capitalize("total"), formatCurrency(cart.total()));
  console.log(cart.describe());
  console.log("area", circleArea(2));
  console.log("sum", add(2, 3), "diff", subtract(5, 3));
}

main();
EOF

printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x02' > assets/logo.png

g add -A
g commit -q -m "Add cart"

echo "fixture ready: $dest (branch feature/cart, base main)"
