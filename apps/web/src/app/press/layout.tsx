import type { Metadata } from "next";
import type { ReactNode } from "react";

/**
 * Screenshot-only routes. Kept out of search results — these render marketing
 * copy baked into images and would compete with the real landing page.
 */
export const metadata: Metadata = {
  title: "Press",
  robots: { index: false, follow: false },
};

export default function PressLayout({ children }: { children: ReactNode }) {
  return children;
}
