"""Service-layer exceptions. Routes translate these to HTTP responses."""


class TicketingError(Exception):
    """Base class for all service-level errors."""


class EventNotFoundError(TicketingError):
    pass


class ReservationNotFoundError(TicketingError):
    pass


class InsufficientSeatsError(TicketingError):
    pass


class ReservationNotPendingError(TicketingError):
    """Reservation cannot be confirmed because it's already confirmed/expired."""


class ReservationExpiredError(TicketingError):
    pass


class ConcurrentReservationConflictError(TicketingError):
    """Lock could not be acquired — another reservation in flight for this event."""


class TooManySeatsRequestedError(TicketingError):
    pass
