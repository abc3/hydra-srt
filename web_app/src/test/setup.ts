import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach } from 'vitest';

afterEach(() => {
  cleanup();
});

// antd / responsive code paths sometimes require matchMedia
if (!window.matchMedia) {
  window.matchMedia = ((query: string) =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList) as typeof window.matchMedia;
}

if (!globalThis.ResizeObserver) {
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
}

// Recharts ResponsiveContainer reads element dimensions; jsdom reports 0 by default.
Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
  configurable: true,
  value: 1024,
});

Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  value: 768,
});

// antd/rc-table may call getComputedStyle with a pseudo element; jsdom doesn't implement it.
window.getComputedStyle = (() =>
  ({
    getPropertyValue: () => '',
  }) as unknown as CSSStyleDeclaration) as typeof window.getComputedStyle;
