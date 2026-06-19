"""The Hanomi welcome email sent to every demo requester."""

SUBJECT = "Thanks for reaching out to Hanomi"


def render(name: str) -> str:
    """Render the welcome email body for a given lead name."""
    return f"""Hello {name},

Thank you for your interest in Hanomi.ai and for requesting a demo through our \
website. We're excited to show you how our solution can help.

We would like to schedule a 30-45 minute demo call to understand your \
requirements better and demonstrate how Hanomi.ai can address your needs.

Please confirm your preferred date and time slot. We are available between: \
8:00 AM - 10:30 PM IST

Once confirmed, we'll send you a calendar invitation with the Gmeet meeting \
link. Looking forward to connecting with you soon!

Regards,
Team Hanomi

--
Hanomi.ai | Customer Success
3D models -> 2D drawings
"""
