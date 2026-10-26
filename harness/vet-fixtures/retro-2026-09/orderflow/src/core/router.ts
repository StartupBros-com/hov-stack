import { findOrder } from "../db/orderRepo.js";
import { query } from "../internal/pg-driver.js";

export async function route(path: string): Promise<any> {
  if (path.startsWith("/orders/")) {
    return findOrder(path.split("/")[2]!);
  }
  if (path === "/health") {
    return query("select 1", []);
  }
  return null;
}
