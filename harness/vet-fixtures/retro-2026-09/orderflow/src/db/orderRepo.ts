import type { Order } from "./generated-types.js";
import { query } from "../internal/pg-driver.js";

export async function findOrder(id: string): Promise<Order | null> {
  const rows = await query("select * from orders where id = $1", [id]);
  return (rows[0] as Order) ?? null;
}
