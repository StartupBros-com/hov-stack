"""Payment reminders."""

from invoicer.money import format_cents
from invoicer.totals import invoice_total


def due_invoices(invoices, today):
    """Unpaid invoices due on or before today."""
    return [inv for inv in invoices if not inv.paid and inv.due_on <= today]


def overdue_invoices(invoices, today):
    """Unpaid invoices past their due date."""
    return [inv for inv in invoices if not inv.paid and inv.due_on < today]


def reminder_text(inv, today):
    days = (today - inv.due_on).days
    when = "due today" if days == 0 else f"{days} days overdue"
    return f"Invoice {inv.invoice_id} for {format_cents(invoice_total(inv))} is {when}."


def send_reminders(invoices, today, send):
    """Send one reminder per unpaid invoice that is due or overdue."""
    for inv in due_invoices(invoices, today) + overdue_invoices(invoices, today):
        send(inv.customer, reminder_text(inv, today))
