import type { ReactNode } from 'react';

export type BreadcrumbItem = {
  href?: string;
  title: ReactNode;
};

declare global {
  interface Window {
    setBreadcrumbItems?: (items: BreadcrumbItem[]) => void;
  }
}

export {};
