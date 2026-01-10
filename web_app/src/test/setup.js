import '@testing-library/jest-dom/vitest';

// antd / responsive code paths sometimes require matchMedia
if (!window.matchMedia) {
  window.matchMedia = () => ({
    matches: false,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  });
}

// recharts uses ResizeObserver via ResponsiveContainer
if (!globalThis.ResizeObserver) {
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
}

// antd/rc-table may call getComputedStyle with a pseudo element; jsdom doesn't implement it.
window.getComputedStyle = () => ({
  getPropertyValue: () => '',
});

