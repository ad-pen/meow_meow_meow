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
    }
}
