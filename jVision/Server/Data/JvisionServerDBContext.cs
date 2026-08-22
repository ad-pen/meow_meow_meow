using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using jVision.Server.Models;
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;
using jVision.Shared.Models;

namespace jVision.Server.Data
{
    public class JvisionServerDBContext : IdentityDbContext<ApplicationUser>
    {
        public JvisionServerDBContext(DbContextOptions<JvisionServerDBContext> options) : base(options)
        {
        }
        public DbSet<JvisUser> JvisUsers { get; set; }

        public DbSet<Box> Boxes { get; set; }

        public DbSet<Cred> Cred { get; set; }

        public DbSet<LogEntry> LogEntry { get; set; }

        public DbSet<ScanUpload> ScanUpload { get; set; }

        public DbSet<UploadedScanHost> UploadedScanHost { get; set; }

        public DbSet<TeamIp> TeamIp { get; set; }

        protected override void OnModelCreating(ModelBuilder builder)
        {
            base.OnModelCreating(builder);

            // One row per operator+address pair; the recorder relies on this to
            // upsert rather than pile up a row per request.
            builder.Entity<TeamIp>()
                .HasIndex(t => new { t.Operator, t.Ip })
                .IsUnique();
        }
    }
}
