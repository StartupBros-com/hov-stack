// Source of truth for the database shape.
export const orders = {
  id: "uuid",
  customerId: "uuid",
  status: "text",
  totalCents: "integer",
  currency: "text",
  placedAt: "timestamptz",
} as const;

export const refunds = {
  id: "uuid",
  orderId: "uuid",
  amountCents: "integer",
  reason: "text",
  issuedAt: "timestamptz",
} as const;
