// AUTO-GENERATED. Do not edit.
export type Order = {
  id: string;
  customerId: string;
  status: string;
  totalCents: number;
  placedAt: string;
};

export type Refund = {
  id: string;
  orderId: string;
  amountCents: number;
  issuedAt: string;
};
