// ref https://github.com/floscodes/zerve/blob/main/src/status.zig
pub const Status = enum(u32) {
    // INFORMATION RESPONSES

    CONTINUE = 100,
    SWITCHING_PROTOCOLS = 101,
    PROCESSING = 102,
    EARLY_HINTS = 103,

    // SUCCESSFUL RESPONSES
    OK = 200,
    CREATED = 201,
    ACCEPTED = 202,
    NON_AUTHORATIVE_INFORMATION = 203,
    NO_CONTENT = 204,
    RESET_CONTENT = 205,
    PARTIAL_CONTENT = 206,
    MULTI_STATUS = 207,
    ALREADY_REPORTED = 208,
    IM_USED = 226,

    // REDIRECTION MESSAGES
    MULTIPLE_CHOICES = 300,
    MOVED_PERMANENTLY = 301,
    FOUND = 302,
    SEE_OTHER = 303,
    NOT_MODIFIED = 304,
    USE_PROXY = 305,
    SWITCH_PROXY = 306,
    TEMPORARY_REDIRECT = 307,
    PERMANENT_REDIRECT = 308,

    // CLIENT ERROR RESPONSES
    BAD_REQUEST = 400,
    UNAUTHORIZED = 401,
    PAYMENT_REQUIRED = 402,
    FORBIDDEN = 403,
    NOT_FOUND = 404,
    METHOD_NOT_ALLOWED = 405,
    NOT_ACCEPTABLE = 406,
    PROXY_AUTHENTICATION_REQUIRED = 407,
    REQUEST_TIMEOUT = 408,
    CONFLICT = 409,
    GONE = 410,
    LENGTH_REQUIRED = 411,
    PRECONDITION_FAILED = 412,
    PAYLOAD_TOO_LARGE = 213,
    URI_TOO_LONG = 414,
    UNSUPPORTED_MEDIA_TYPE = 415,
    RANGE_NOT_SATISIFIABLE = 416,
    EXPECTATION_FAILED = 417,
    I_AM_A_TEAPOT = 418,
    MISDIRECTED_REQUEST = 421,
    UNPROCESSABLE_CONTENT = 422,
    LOCKED = 423,
    FAILED_DEPENDENCY = 424,
    TOO_EARLY = 425,
    UPGRADE_REQUIRED = 426,
    PRECONDITION_REQUIRED = 428,
    TOO_MANY_REQUESTS = 429,
    REQUESTS_HEADER_FIELDS_TOO_LARGE = 431,
    UNAVAILABLE_FOR_LEGAL_REASONS = 451,

    // SERVER RESPONSES
    INTERNAL_SERVER_ERROR = 500,
    NOT_IMPLEMETED = 501,
    BAD_GATEWAY = 502,
    SERVUCE_UNAVAILABLE = 503,
    GATEWAY_TIMEOUT = 504,
    HTTP_VERSION_NOT_SUPPORTED = 505,
    VARIANT_ALSO_NEGOTIATES = 506,
    INSUFFICIENT_STORAGE = 507,
    LOOP_DETECTED = 508,
    NOT_EXTENDED = 510,
    NETWORK_AUTHENTICATION_REQUIRED = 511,

    /// Returns a stringified version of a HTTP status.
    /// E.g. `Status.OK.stringify()`  will be "200 OK".
    pub fn stringify(self: Status) []const u8 {
        switch (self) {
            Status.CONTINUE => return "100 Continue",
            Status.SWITCHING_PROTOCOLS => return "101 Switching Protocols",
            Status.PROCESSING => return "102 Processing",
            Status.EARLY_HINTS => return "103 Early Hints",
            Status.OK => return "200 OK",
            Status.CREATED => return "201 Created",
            Status.ACCEPTED => return "202 Accepted",
            Status.NON_AUTHORATIVE_INFORMATION => return "203 Non-Authorative Information",
            Status.NO_CONTENT => return "204 No Content",
            Status.RESET_CONTENT => return "205 Reset Content",
            Status.PARTIAL_CONTENT => return "206 Partial Content",
            Status.MULTI_STATUS => return "207 Multi-Status",
            Status.ALREADY_REPORTED => return "208 Already Reported",
            Status.IM_USED => return "226 IM Used",
            Status.MULTIPLE_CHOICES => return "300 Multiple Choices",
            Status.MOVED_PERMANENTLY => return "301 Moved Permanently",
            Status.FOUND => return "302 Found",
            Status.SEE_OTHER => return "303 See Other",
            Status.NOT_MODIFIED => return "304 Not Modified",
            Status.USE_PROXY => return "305 Use Proxy",
            Status.SWITCH_PROXY => return "306 Switch Proxy",
            Status.TEMPORARY_REDIRECT => return "307 Temporary Redirect",
            Status.PERMANENT_REDIRECT => return "308 Permanent Redirect",
            Status.BAD_REQUEST => return "400 Bad Request",
            Status.UNAUTHORIZED => return "401 Unauthorized",
            Status.PAYMENT_REQUIRED => return "402 Payment Required",
            Status.FORBIDDEN => return "403 Forbidden",
            Status.NOT_FOUND => return "404 Not Found",
            Status.METHOD_NOT_ALLOWED => return "405 Method Not Allowed",
            Status.NOT_ACCEPTABLE => return "406 Not Acceptable",
            Status.PROXY_AUTHENTICATION_REQUIRED => return "407 Proxy Authentication Required",
            Status.REQUEST_TIMEOUT => return "408 Request Timeout",
            Status.CONFLICT => return "409 Conflict",
            Status.GONE => return "410 Gone",
            Status.LENGTH_REQUIRED => return "411 Length Required",
            Status.PRECONDITION_FAILED => return "412 Precondition Failed",
            Status.PAYLOAD_TOO_LARGE => return "413 Payload Too Large",
            Status.URI_TOO_LONG => return "414 URI Too Long",
            Status.UNSUPPORTED_MEDIA_TYPE => return "415 Unsupported Media Type",
            Status.RANGE_NOT_SATISIFIABLE => return "416 Range Not Satisfiable",
            Status.EXPECTATION_FAILED => return "417 Expectation Failed",
            Status.I_AM_A_TEAPOT => return "418 I'm a teapot",
            Status.MISDIRECTED_REQUEST => return "421 Misdirected Request",
            Status.UNPROCESSABLE_CONTENT => return "422 Unprocessable Content",
            Status.LOCKED => return "423 Locked",
            Status.FAILED_DEPENDENCY => return "424 Failed Dependency",
            Status.TOO_EARLY => return "425 Too Early",
            Status.UPGRADE_REQUIRED => return "426 Upgrade Required",
            Status.PRECONDITION_REQUIRED => return "428 Precondition Required",
            Status.TOO_MANY_REQUESTS => return "429 Too Many Requests",
            Status.REQUESTS_HEADER_FIELDS_TOO_LARGE => return "431 Request Header Fields Too Large",
            Status.UNAVAILABLE_FOR_LEGAL_REASONS => return "451 Unavailable For Legal Reasons",
            Status.INTERNAL_SERVER_ERROR => return "500 Internal Server Error",
            Status.NOT_IMPLEMETED => return "501 Not Implemented",
            Status.BAD_GATEWAY => return "502 Bad Gateway",
            Status.SERVUCE_UNAVAILABLE => return "503 Service Unavailable",
            Status.GATEWAY_TIMEOUT => return "504 Gateway Timeout",
            Status.HTTP_VERSION_NOT_SUPPORTED => return "505 HTTP Version Not Supported",
            Status.VARIANT_ALSO_NEGOTIATES => return "506 Variant Also Negotiates",
            Status.INSUFFICIENT_STORAGE => return "507 Insufficient Storage",
            Status.LOOP_DETECTED => return "508 Loop Detected",
            Status.NOT_EXTENDED => return "510 Not Extended",
            Status.NETWORK_AUTHENTICATION_REQUIRED => return "511 Network Authentication Required",
        }
    }

    /// Parses a given u32 code and returns the corresponding `Status`.
    /// E.g. `Status.code(200)` will return `Status.OK`.
    /// The program will panic if the passed code does not exist.
    pub fn code(n: u32) Status {
        return @enumFromInt(n);
    }
};
