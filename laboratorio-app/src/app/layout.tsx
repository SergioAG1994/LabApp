import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "LabAqua | Control de análisis",
  description: "Sistema interno de órdenes de análisis de agua",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es-MX">
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
