import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Weed Man Mailing Program",
  description: "Order mailers and door hangers for your franchise.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:wght@600;700;800&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
