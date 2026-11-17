type Invoice = { id: string; customer: string; total: string; status: "paid" | "open" };

export function InvoiceTable({ invoices }: { invoices: Invoice[] }) {
  return (
    <table className="w-full text-sm text-slate-900">
      <thead>
        <tr className="text-left text-slate-500">
          <th className="py-2">Invoice</th>
          <th className="py-2">Customer</th>
          <th className="py-2 text-right">Total</th>
        </tr>
      </thead>
      <tbody>
        {invoices.map((inv) => (
          <tr key={inv.id} className="border-t border-slate-200">
            <td className="py-2">{inv.id}</td>
            <td className="py-2">{inv.customer}</td>
            <td className="py-2 text-right">{inv.total}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
