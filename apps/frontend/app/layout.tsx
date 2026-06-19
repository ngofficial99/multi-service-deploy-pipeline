import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Hanomi — CAD to 2D in minutes",
  description:
    "Generate production-ready 2D technical drawings from your 3D CAD models. Native CAD output. Assembly-aware. Your standards.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
