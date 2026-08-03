using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using jVision.Server.Data;
using jVision.Server.Hubs;
using jVision.Shared.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace jVision.Server.Controllers
{
    [Route("[controller]")]
    [ApiController]
    [Authorize]
    public class LogsController : ControllerBase
    {
        private readonly JvisionServerDBContext _context;
        private readonly IHubContext<BoxHub, IBoxClient> _hubContext;

        public LogsController(JvisionServerDBContext context, IHubContext<BoxHub, IBoxClient> hubContext)
        {
            _context = context;
            _hubContext = hubContext;
        }

        // GET /logs?operator=mustafa&source=zsh&since=2026-08-03T14:00:00Z&search=nmap&limit=500
        [HttpGet]
        public async Task<ActionResult<IEnumerable<LogEntry>>> Get(
            [FromQuery(Name = "operator")] string op = null,
            [FromQuery] string source = null,
            [FromQuery] DateTime? since = null,
            [FromQuery] string search = null,
            [FromQuery] int limit = 500)
        {
            if (limit <= 0 || limit > 5000) limit = 500;

            IQueryable<LogEntry> q = _context.LogEntry;
            if (!string.IsNullOrEmpty(op))     q = q.Where(l => l.Operator == op);
            if (!string.IsNullOrEmpty(source)) q = q.Where(l => l.Source == source);
            if (since.HasValue)                q = q.Where(l => l.Timestamp >= since.Value);
            if (!string.IsNullOrEmpty(search)) q = q.Where(l => EF.Functions.Like(l.Line, "%" + search + "%"));

            return await q.OrderByDescending(l => l.Timestamp).Take(limit).ToListAsync();
        }

        // GET /logs/operators -- for the filter dropdown in the UI.
        [HttpGet("operators")]
        public async Task<ActionResult<IEnumerable<string>>> Operators()
        {
            return await _context.LogEntry
                .Select(l => l.Operator)
                .Distinct()
                .OrderBy(o => o)
                .ToListAsync();
        }

        // POST /logs -- batch upload from the sync client. Server stamps the
        // operator name from the authenticated user, ignoring any value in the
        // payload (prevents impersonation via a mislabelled batch).
        [HttpPost]
        public async Task<IActionResult> Post([FromBody] List<LogEntry> entries)
        {
            if (entries == null || entries.Count == 0) return Ok(0);

            string op = User.Identity?.Name ?? "unknown";
            foreach (var e in entries)
            {
                e.Operator = op;
                if (e.Timestamp == default) e.Timestamp = DateTime.UtcNow;
                if (string.IsNullOrEmpty(e.Source)) e.Source = "unknown";
                if (e.Line == null) e.Line = "";
            }

            await _context.LogEntry.AddRangeAsync(entries);
            await _context.SaveChangesAsync();
            await _hubContext.Clients.All.LogsAdded(entries.Count);
            return Ok(entries.Count);
        }
    }
}
