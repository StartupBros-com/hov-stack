import type { ButtonHTMLAttributes } from "react";

export function Button({ className = "", ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      {...props}
      className={`w-full rounded-md bg-brand px-4 py-2 text-sm font-medium text-white sm:w-auto ${className}`}
    />
  );
}
