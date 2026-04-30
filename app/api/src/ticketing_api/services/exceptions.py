"""Service-layer exceptions. Routes translate these to HTTP responses."""


class TicketingError(Exception):
    """Base class for all service-level errors."""


class EventNotFound(TicketingError):
    pass


class ReservationNotFound(TicketingError):
    pass


class InsufficientSeats(TicketingError):
    pass


class ReservationNotPending(TicketingError):
    """Reservation cannot be confirmed because it's already confirmed/expired."""


class ReservationExpired(TicketingError):
    pass


class ConcurrentReservationConflict(TicketingError):
    """Lock could not be acquired — another reservation in flight for this event."""


class TooManySeatsRequested(TicketingError):
    pass