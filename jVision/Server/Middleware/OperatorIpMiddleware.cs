using System;
using System.Collections.Concurrent;
using System.Net;
using System.Threading.Tasks;
using jVision.Server.Data;
using jVision.Shared.Models;
using Microsoft.AspNetCore.Http;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace jVision.Server.Middleware
{
    // Stamps operator -> source-address pairs for the Team IPs page. Runs on
    // every authenticated request, so an operator shows up whether they push
    // logs with the sync daemon or just open the web UI.
    public class OperatorIpMiddleware
    {
        private readonly RequestDelegate _next;

        // Without this, every request would round-trip the DB just to bump
        // LastSeen. Key is "operator|ip".
        private static readonly ConcurrentDictionary<string, DateTime> _seen =
            new ConcurrentDictionary<string, DateTime>();
        private static readonly TimeSpan RefreshAfter = TimeSpan.FromMinutes(5);

        public OperatorIpMiddleware(RequestDelegate next) => _next = next;

        public async Task InvokeAsync(HttpContext ctx)
        {
            await Record(ctx);
            await _next(ctx);
        }

        private static async Task Record(HttpContext ctx)
        {
            if (ctx.User?.Identity?.IsAuthenticated != true) return;

            var op = ctx.User.Identity.Name;
            var ip = Normalize(ctx.Connection.RemoteIpAddress);
            if (string.IsNullOrEmpty(op) || string.IsNullOrEmpty(ip)) return;

            var now = DateTime.UtcNow;
            var key = op + "|" + ip;
            if (_seen.TryGetValue(key, out var last) && now - last < RefreshAfter) return;
            _seen[key] = now;

            var db = ctx.RequestServices.GetService<JvisionServerDBContext>();
            if (db == null) return;

            try
            {
                var row = await db.TeamIp.FirstOrDefaultAsync(t => t.Operator == op && t.Ip == ip);
                if (row == null)
                    db.TeamIp.Add(new TeamIp { Operator = op, Ip = ip, FirstSeen = now, LastSeen = now });
                else
                    row.LastSeen = now;

                await db.SaveChangesAsync();
            }
            catch (DbUpdateException)
            {
                // Two concurrent first-requests from the same operator can both
                // miss the row and race the unique index. Losing one is fine --
                // the winner already recorded the pair.
                _seen.TryRemove(key, out _);
            }
        }

        private static string Normalize(IPAddress addr)
        {
            if (addr == null) return null;
            if (addr.IsIPv4MappedToIPv6) addr = addr.MapToIPv4();
            return addr.ToString();
        }
    }
}
