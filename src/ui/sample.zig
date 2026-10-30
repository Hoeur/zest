//! Placeholder dashboard figures from the mockup. Nothing records test history
//! yet, so the dashboard labels all of this as sample data. Replace with
//! snapshots from the core once it exists. Secrets stay masked here too.

const state = @import("state.zig");

pub const Trend = enum { up_good, down_good, down_bad };

pub const Stat = struct {
    label: []const u8,
    value: []const u8,
    unit: []const u8 = "",
    delta: []const u8,
    note: []const u8 = "vs. last 7 days",
    trend: Trend,
    icon: []const u8,
    color: u32,
    tint: u32,
    bars: [12]f32,
};

pub const Day = struct { label: []const u8, passed: f32, failed: f32 };

pub const Activity = struct {
    title: []const u8,
    detail: []const u8,
    age: []const u8,
    outcome: enum { passed, failed, neutral },
};

pub const Run = struct {
    name: []const u8,
    suite: []const u8,
    environment: []const u8,
    passed: bool,
    response: []const u8,
    started: []const u8,
};

pub const days = [_]Day{
    .{ .label = "Mar 10", .passed = 195, .failed = 60 },
    .{ .label = "Mar 11", .passed = 250, .failed = 65 },
    .{ .label = "Mar 12", .passed = 232, .failed = 62 },
    .{ .label = "Mar 13", .passed = 298, .failed = 75 },
    .{ .label = "Mar 14", .passed = 330, .failed = 90 },
    .{ .label = "Mar 15", .passed = 375, .failed = 105 },
    .{ .label = "Mar 16", .passed = 420, .failed = 115 },
};

pub const activity = [_]Activity{
    .{ .title = "User authentication API test passed", .detail = "POST /api/v1/auth/login", .age = "2m ago", .outcome = .passed },
    .{ .title = "Payment flow test failed", .detail = "Test suite: Checkout Flow", .age = "8m ago", .outcome = .failed },
    .{ .title = "Load test completed", .detail = "1,000 users \u{00B7} 5 min \u{00B7} 1,240 rps", .age = "15m ago", .outcome = .neutral },
    .{ .title = "Environment switched to Production", .detail = "by John Doe", .age = "32m ago", .outcome = .neutral },
    .{ .title = "Scheduled test suite started", .detail = "Nightly Regression Suite", .age = "1h ago", .outcome = .neutral },
};

pub const runs = [_]Run{
    .{ .name = "User Login", .suite = "Auth API", .environment = "Production", .passed = true, .response = "210 ms", .started = "Mar 16, 2024, 10:24 AM" },
    .{ .name = "Create Project", .suite = "Projects API", .environment = "Staging", .passed = true, .response = "342 ms", .started = "Mar 16, 2024, 10:22 AM" },
    .{ .name = "Payment Flow", .suite = "Checkout Flow", .environment = "Production", .passed = false, .response = "1.2 s", .started = "Mar 16, 2024, 10:20 AM" },
    .{ .name = "Get User Profile", .suite = "Users API", .environment = "Production", .passed = true, .response = "180 ms", .started = "Mar 16, 2024, 10:18 AM" },
    .{ .name = "Search Products", .suite = "Catalog API", .environment = "Staging", .passed = true, .response = "420 ms", .started = "Mar 16, 2024, 10:15 AM" },
};

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const AssertionRow = struct {
    target: []const u8,
    operator: []const u8,
    expected: []const u8,
    note: []const u8,
};

pub const body_types = [_][]const u8{ "none", "form-data", "x-www-form-urlencoded", "raw", "binary", "GraphQL" };

pub const params = [_]Pair{
    .{ .key = "notify", .value = "true" },
    .{ .key = "source", .value = "ztest" },
};

pub const request_headers = [_]Pair{
    .{ .key = "Content-Type", .value = "application/json" },
    .{ .key = "Accept", .value = "application/json" },
    .{ .key = "X-Api-Key", .value = "{{apiKey}}" },
};

pub const auth = [_]Pair{
    .{ .key = "Type", .value = "Bearer Token" },
    .{ .key = "Token", .value = "{{apiKey}}" },
};

pub const request_body = [_][]const u8{
    "{",
    "  \"name\": \"John Doe\",",
    "  \"email\": \"john.doe@example.com\",",
    "  \"password\": \"********\",",
    "  \"role\": \"user\",",
    "  \"preferences\": {",
    "    \"newsletter\": true,",
    "    \"theme\": \"dark\"",
    "  }",
    "}",
};

pub const variables = [_]Pair{
    .{ .key = "{{baseUrl}}", .value = "https://api.ztest.dev" },
    .{ .key = "{{apiKey}}", .value = "********" },
    .{ .key = "{{userId}}", .value = "usr_123456" },
    .{ .key = "{{env}}", .value = "production" },
};

pub const response_body = [_][]const u8{
    "{",
    "  \"id\": \"usr_123456\",",
    "  \"name\": \"John Doe\",",
    "  \"email\": \"john.doe@example.com\",",
    "  \"role\": \"user\",",
    "  \"token\": \"********\",",
    "  \"expiresIn\": 3600,",
    "  \"createdAt\": \"2024-03-16T10:22:41Z\",",
    "  \"preferences\": {",
    "    \"newsletter\": true,",
    "    \"theme\": \"dark\"",
    "  }",
    "}",
};

pub const response_headers = [_]Pair{
    .{ .key = "Content-Type", .value = "application/json" },
    .{ .key = "Content-Length", .value = "1229" },
    .{ .key = "Server", .value = "ztest-demo" },
};

pub const response_cookies = [_]Pair{
    .{ .key = "session", .value = "********" },
    .{ .key = "theme", .value = "dark" },
};

pub const response_raw = [_][]const u8{
    "HTTP/1.1 200 OK",
    "Content-Type: application/json",
    "Content-Length: 1229",
    "",
    "{\"id\":\"usr_123456\",\"name\":\"John Doe\",\"token\":\"********\"}",
};

pub const assertions = [_]AssertionRow{
    .{ .target = "Status code", .operator = "equals", .expected = "200", .note = "Expected response status code to be 200." },
    .{ .target = "Response time", .operator = "less than", .expected = "500 ms", .note = "Expected response time to be less than 500 ms." },
    .{ .target = "Body property", .operator = "exists", .expected = "body.token", .note = "Expected response to have property body.token." },
};

pub const Suite = struct { name: []const u8, tests: u32, last_run: []const u8, health: state.SuiteHealth };

pub const suites = [_]Suite{
    .{ .name = "Checkout Regression", .tests = 42, .last_run = "2h ago", .health = .active },
    .{ .name = "User Management", .tests = 28, .last_run = "1d ago", .health = .active },
    .{ .name = "Payment Flow", .tests = 35, .last_run = "6h ago", .health = .active },
    .{ .name = "Authentication", .tests = 18, .last_run = "1d ago", .health = .active },
    .{ .name = "Product Catalog", .tests = 31, .last_run = "3d ago", .health = .failing },
    .{ .name = "Order Management", .tests = 24, .last_run = "5d ago", .health = .active },
    .{ .name = "Search Functionality", .tests = 16, .last_run = "2d ago", .health = .active },
    .{ .name = "Notifications", .tests = 12, .last_run = "4d ago", .health = .scheduled },
    .{ .name = "Admin APIs", .tests = 27, .last_run = "6d ago", .health = .active },
    .{ .name = "Analytics", .tests = 20, .last_run = "1w ago", .health = .scheduled },
    .{ .name = "File Upload", .tests = 14, .last_run = "1w ago", .health = .active },
    .{ .name = "Integrations", .tests = 19, .last_run = "1w ago", .health = .scheduled },
};

pub const SuiteTest = struct {
    name: []const u8,
    method: []const u8,
    path: []const u8,
    duration: []const u8,
    outcome: state.Outcome,
};

pub const TestGroup = struct {
    name: []const u8,
    summary: []const u8,
    duration: []const u8,
    outcome: state.Outcome,
    tests: []const SuiteTest,
};

pub const groups = [_]TestGroup{
    .{ .name = "Cart Operations", .summary = "6/6 passed \u{00B7} 28s", .duration = "28s", .outcome = .passed, .tests = &.{} },
    .{
        .name = "Checkout Process",
        .summary = "3/6 passed \u{00B7} 2 failed \u{00B7} 1.2m",
        .duration = "1.2m",
        .outcome = .failed,
        .tests = &.{
            .{ .name = "Add items to cart", .method = "POST", .path = "/api/cart/items", .duration = "210 ms", .outcome = .passed },
            .{ .name = "Proceed to checkout", .method = "POST", .path = "/api/checkout", .duration = "342 ms", .outcome = .passed },
            .{ .name = "Select shipping method", .method = "POST", .path = "/api/checkout/shipping", .duration = "498 ms", .outcome = .passed },
            .{ .name = "Process payment with valid card", .method = "POST", .path = "/api/payments/process", .duration = "1.2 s", .outcome = .failed },
            .{ .name = "Verify order confirmation", .method = "GET", .path = "/api/orders/confirmation", .duration = "890 ms", .outcome = .failed },
            .{ .name = "Order appears in order history", .method = "GET", .path = "/api/orders", .duration = "320 ms", .outcome = .skipped },
        },
    },
    .{ .name = "Order Confirmation", .summary = "5/5 passed \u{00B7} 46s", .duration = "46s", .outcome = .passed, .tests = &.{} },
};

pub const test_details = [_][]const []const u8{
    &.{ "POST /api/payments/process", "Content-Type: application/json", "", "{ \"card\": \"****4242\", \"amount\": 129.99 }" },
    &.{ "HTTP/1.1 500 Internal Server Error", "", "{ \"error\": \"Internal server error\", \"code\": \"PAY_500\" }" },
    &.{
        "10:24:32  INFO   Sending payment request to /api/payments/process",
        "10:24:33  INFO   Request payload: { \"card\": \"****4242\", \"amount\": 129.99 }",
        "10:24:33  ERROR  Payment request failed with status 500",
        "10:24:33  ERROR  { \"error\": \"Internal server error\", \"code\": \"PAY_500\" }",
    },
    &.{ "status == 200", "  expected 200, got 500" },
};

pub const rps = [_]f32{ 0, 320, 760, 1180, 1520, 1760, 1880, 1960, 2010, 1990, 2040, 2020, 2070, 2050, 2030, 2080, 2060, 2090, 2070, 2110, 2080, 2120, 2090, 2100 };
pub const p50 = [_]f32{ 180, 190, 200, 210, 205, 200, 195, 210, 205, 200, 215, 205, 200, 210, 205, 200, 215, 210, 205, 200, 210, 205, 240, 220 };
pub const p95 = [_]f32{ 280, 340, 390, 430, 420, 410, 440, 420, 430, 470, 430, 420, 440, 430, 420, 450, 430, 440, 430, 420, 450, 470, 700, 500 };
pub const p99 = [_]f32{ 420, 580, 720, 780, 760, 790, 770, 800, 780, 1050, 790, 770, 800, 790, 780, 820, 790, 1000, 800, 790, 830, 900, 1450, 950 };
pub const error_rate = [_]f32{ 0, 1.1, 0.5, 1.2, 0.4, 0.9, 0.5, 1.4, 0.6, 3.6, 0.8, 0.5, 0.9, 0.4, 0.7, 0.5, 0.6, 0.4, 0.8, 1.6, 0.5, 0.9, 1.2, 0.3 };
pub const cpu = [_]f32{ 8, 24, 38, 48, 58, 62, 66, 64, 68, 66, 70, 67, 71, 69, 72, 68, 73, 70, 72, 69, 74, 71, 73, 72 };
pub const memory = [_]f32{ 0.6, 0.9, 1.2, 1.4, 1.6, 1.7, 1.8, 1.9, 2.0, 2.0, 2.1, 2.1, 2.2, 2.2, 2.2, 2.3, 2.3, 2.3, 2.4, 2.3, 2.4, 2.4, 2.4, 2.4 };
pub const users = [_]f32{ 0, 90, 180, 270, 360, 450, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 250, 0 };

pub const Endpoint = struct {
    path: []const u8,
    method: []const u8,
    requests: []const u8,
    throughput: []const u8,
    average: []const u8,
    p95: []const u8,
    p99: []const u8,
    error_rate: []const u8,
    failing: bool,
};

pub const endpoints = [_]Endpoint{
    .{ .path = "/v1/auth/login", .method = "POST", .requests = "302,421", .throughput = "504", .average = "220 ms", .p95 = "480 ms", .p99 = "820 ms", .error_rate = "0.4%", .failing = false },
    .{ .path = "/v1/projects", .method = "GET", .requests = "418,220", .throughput = "697", .average = "180 ms", .p95 = "340 ms", .p99 = "620 ms", .error_rate = "0.2%", .failing = false },
    .{ .path = "/v1/projects/{id}", .method = "GET", .requests = "248,112", .throughput = "413", .average = "310 ms", .p95 = "680 ms", .p99 = "1.2 s", .error_rate = "1.8%", .failing = true },
    .{ .path = "/v1/payments", .method = "POST", .requests = "152,330", .throughput = "254", .average = "420 ms", .p95 = "890 ms", .p99 = "1.8 s", .error_rate = "2.4%", .failing = true },
    .{ .path = "/v1/users/profile", .method = "GET", .requests = "124,237", .throughput = "207", .average = "240 ms", .p95 = "520 ms", .p99 = "1.0 s", .error_rate = "0.6%", .failing = false },
};
