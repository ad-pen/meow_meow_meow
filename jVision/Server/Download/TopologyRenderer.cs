using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Xml;
using jVision.Server.Models;

namespace jVision.Server.Download
{
    // Network topology renderer — row-wise layout (3 subnets per row):
    //
    //   +--------------------------+
    //   |     Attacker Network     |   dashed box, hooded-figure monitor
    //   +--------------------------+
    //              |  ↓
    //          [ ROUTER ]             clean cyan cylinder, no coloured arrow shapes
    //              |  ↓
    //   [subnet A] [subnet B] [subnet C]   dashed sub-boxes, 3 per row
    //   [subnet D] [subnet E] [subnet F]
    //
    //  Each device shows an OS-specific monitor icon (Linux Tux or Windows flag)
    //  and the IP address only — no hostname notes, no "Production Network" frame,
    //  no subnet labels next to the router.
    //
    // Mapping from jVision data:
    //   Box.Subnet -> sub-environment label (normalized to /24 if bare IP/empty)
    //   Box.Ip     -> bold label under each device
    //   Box.Os/Box.Hostname -> icon selector (either field can indicate windows/linux)
    public static class TopologyRenderer
    {
        // ---- Layout constants ----
        private const int CanvasMinW = 1280;
        private const int OuterPadX = 45;

        private const int AttackerW = 200, AttackerH = 180;
        private const int AttackerTopY = 30;

        private const int RouterW = 100, RouterH = 58;
        private const int RouterTopY = 280;

        // OuterFrameTopY is reused only as the Y where subnet rows begin
        // (no actual outer frame is drawn any more).
        private const int OuterFrameTopY = 400;
        private const int OuterFramePad = 0;

        // Sub-environment box
        private const int SubBoxMinW = 380;
        private const int SubBoxHeaderH = 28;
        private const int SubBoxPadX = 22, SubBoxPadY = 14;

        // Device cell (icon + IP label only)
        private const int IconW = 52, IconH = 45;
        private const int CellW = 120, CellH = 95;
        private const int DevPerRow = 3;

        private const int SubGapX = 25, SubGapY = 20;
        private const int SubCols = 3;                     // 3 subnet columns (row-wise layout)

        // ==================== data grouping ====================

        private static Version TryParseIp(string ip) =>
            Version.TryParse(ip ?? "", out var v) ? v : new Version(0, 0, 0, 0);

        private static List<(string Subnet, List<Box> Hosts)> GroupBySubnet(List<Box> boxes)
        {
            return boxes
                .GroupBy(b => NormalizeSubnet(b))
                .OrderByDescending(g => g.Count())          // biggest first (best fit for 2-col grid)
                .ThenBy(g => g.Key, StringComparer.Ordinal)
                .Select(g => (g.Key, g.OrderBy(b => TryParseIp(b.Ip)).ToList()))
                .ToList();
        }

        // The scan client writes whatever came from `-s ...` into Box.Subnet -- a
        // hostname, an IP, or a CIDR. Normalize everything to a /24 network
        // string so hosts belonging to the same /24 actually group together.
        private static string NormalizeSubnet(Box b)
        {
            var raw = (b.Subnet ?? "").Trim();

            // Explicit CIDR: canonicalize to the network address of that mask so
            // "10.10.10.5/24" and "10.10.10.99/24" collapse to "10.10.10.0/24".
            if (raw.Contains('/'))
            {
                var canon = CanonicalCidr(raw);
                if (canon != null) return canon;
            }

            // Bare IP or empty -- derive a /24 from the host's IP.
            if (!string.IsNullOrEmpty(b.Ip))
            {
                var parts = b.Ip.Split('.');
                if (parts.Length == 4 && parts.All(p => byte.TryParse(p, out _)))
                    return $"{parts[0]}.{parts[1]}.{parts[2]}.0/24";
            }

            return string.IsNullOrEmpty(raw) ? "(no subnet)" : raw;
        }

        private static string CanonicalCidr(string cidr)
        {
            var slash = cidr.IndexOf('/');
            if (slash <= 0) return null;
            var ip = cidr.Substring(0, slash);
            if (!int.TryParse(cidr.Substring(slash + 1), out var bits) || bits < 0 || bits > 32)
                return null;
            var parts = ip.Split('.');
            if (parts.Length != 4) return null;
            var octets = new byte[4];
            for (int i = 0; i < 4; i++)
                if (!byte.TryParse(parts[i], out octets[i])) return null;
            uint addr = ((uint)octets[0] << 24) | ((uint)octets[1] << 16) | ((uint)octets[2] << 8) | octets[3];
            uint mask = bits == 0 ? 0u : 0xFFFFFFFFu << (32 - bits);
            uint net = addr & mask;
            return $"{(byte)(net >> 24)}.{(byte)(net >> 16)}.{(byte)(net >> 8)}.{(byte)net}/{bits}";
        }

        // OS detection: check the Os field, then fall back to hostname keywords
        // so machines the scanner couldn't fingerprint but that carry a
        // descriptive name (dc01, ubuntu-jump, kali-attacker) still get the
        // right icon.
        private static readonly string[] _winKeywords = { "windows", "microsoft" };
        private static readonly string[] _linuxKeywords = {
            "linux", "ubuntu", "debian", "centos", "rhel", "redhat",
            "kali", "arch", "fedora", "suse", "alpine", "unix"
        };

        private static bool IsWindows(Box b)
        {
            var os = (b.Os ?? "").ToLowerInvariant();
            var hn = (b.Hostname ?? "").ToLowerInvariant();
            if (_winKeywords.Any(k => os.Contains(k))) return true;
            if (_winKeywords.Any(k => hn.Contains(k))) return true;
            // Linux keywords in the hostname take precedence over the
            // ambiguous short prefix "win" (avoids classifying "win-ubuntu-jump"
            // as Windows).
            if (_linuxKeywords.Any(k => hn.Contains(k))) return false;
            // Common short forms only if not clearly Linux.
            if (hn.StartsWith("win") || hn.Contains("-win") || hn.Contains(" win")) return true;
            if (hn.StartsWith("dc") || hn.Contains("exchange") || hn.Contains("srv-win")) return true;
            return false;
        }

        // ==================== layout math ====================

        private static int RowsInSub(int hostCount) =>
            Math.Max(1, (hostCount + DevPerRow - 1) / DevPerRow);

        private static int SubBoxH(int hostCount) =>
            SubBoxHeaderH + SubBoxPadY + RowsInSub(hostCount) * CellH + 10;

        private class Layout
        {
            public int CanvasW;
            public int CanvasH;
            public int AttackerX;                // top-left of attacker block
            public int RouterX;                  // top-left of router block
            public int OuterFrameX;
            public int OuterFrameY;
            public int OuterFrameW;
            public int OuterFrameH;
            public List<(int X, int Y, int W, int H)> SubBoxes = new();  // absolute rects
        }

        private static Layout Compute(List<(string Subnet, List<Box> Hosts)> grouped)
        {
            var l = new Layout();

            // Determine outer frame width: uniform sub-box width * SubCols + gaps + padding
            int subBoxW = SubBoxMinW;                                   // uniform
            int innerW = subBoxW * SubCols + SubGapX * (SubCols - 1);
            l.OuterFrameW = innerW + 2 * OuterFramePad;
            l.CanvasW = Math.Max(CanvasMinW, l.OuterFrameW + 2 * OuterPadX);

            // Positions of the fixed elements
            l.OuterFrameX = (l.CanvasW - l.OuterFrameW) / 2;
            l.OuterFrameY = OuterFrameTopY;
            l.AttackerX = (l.CanvasW - AttackerW) / 2;
            l.RouterX   = (l.CanvasW - RouterW) / 2;

            // Grid-place the sub-boxes (row-major, 2 columns).
            int contentX = l.OuterFrameX + OuterFramePad;
            int contentY = l.OuterFrameY + OuterFramePad;

            int rowIdx = 0;
            int colIdx = 0;
            int rowH = 0;
            int yCursor = contentY;

            for (int i = 0; i < grouped.Count; i++)
            {
                int h = SubBoxH(grouped[i].Hosts.Count);
                int x = contentX + colIdx * (subBoxW + SubGapX);
                int y = yCursor;
                l.SubBoxes.Add((x, y, subBoxW, h));

                rowH = Math.Max(rowH, h);
                colIdx++;
                if (colIdx >= SubCols)
                {
                    colIdx = 0;
                    rowIdx++;
                    yCursor += rowH + SubGapY;
                    rowH = 0;
                }
            }
            // Trailing partial row
            int totalContentH = yCursor + rowH - contentY;

            l.OuterFrameH = Math.Max(200, totalContentH + 2 * OuterFramePad);
            l.CanvasH = l.OuterFrameY + l.OuterFrameH + 60;             // 60 for figure caption
            return l;
        }

        // ==================== SVG entry point ====================

        public static byte[] RenderSvg(List<Box> boxes)
        {
            var grouped = GroupBySubnet(boxes);
            var layout = Compute(grouped);

            var sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n");
            sb.Append($"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{layout.CanvasW}\" height=\"{layout.CanvasH}\" viewBox=\"0 0 {layout.CanvasW} {layout.CanvasH}\" font-family=\"Arial, Helvetica, sans-serif\">\n");
            sb.Append(Defs());
            sb.Append($"<rect width=\"{layout.CanvasW}\" height=\"{layout.CanvasH}\" fill=\"#ffffff\"/>\n");

            // Attacker Network
            sb.Append(AttackerBlock(layout.AttackerX, AttackerTopY));

            // Arrow attacker -> router (arrowhead at router end, centred)
            sb.Append(DownArrow(layout.CanvasW / 2, AttackerTopY + AttackerH + 10, RouterTopY - 8));

            // Router — clean cylinder, no coloured diagonal shapes, no subnet label
            sb.Append(CiscoRouter(layout.RouterX, RouterTopY));

            // Arrow router -> subnets (arrowhead at subnet end, centred)
            sb.Append(DownArrow(layout.CanvasW / 2, RouterTopY + RouterH + 20, layout.OuterFrameY - 8));

            // No outer "Production Network" frame or label — subnets appear directly in rows.

            // Sub-environments
            for (int i = 0; i < grouped.Count; i++)
            {
                var (subnet, hosts) = grouped[i];
                var (x, y, w, h) = layout.SubBoxes[i];
                sb.Append(SubEnvBox(x, y, w, h, subnet, hosts));
            }

            // Empty state
            if (grouped.Count == 0)
            {
                sb.Append($"<text x=\"{layout.CanvasW / 2}\" y=\"{layout.OuterFrameY + 80}\" text-anchor=\"middle\" font-size=\"14\" fill=\"#94a3b8\">No hosts discovered yet.</text>\n");
            }

            // Figure caption
            sb.Append($"<text x=\"{layout.CanvasW / 2}\" y=\"{layout.CanvasH - 20}\" text-anchor=\"middle\" font-size=\"12\" font-style=\"italic\" fill=\"#111\">jVision Network Topology — {XmlEscape(DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm 'UTC'", CultureInfo.InvariantCulture))}</text>\n");

            sb.Append("</svg>\n");
            return Encoding.UTF8.GetBytes(sb.ToString());
        }

        // ==================== SVG pieces ====================

        private static string Defs() => @"<defs>
  <!-- Right-pointing polygon in local coords.  With orient=""auto"" on a
       vertical downward line the marker x-axis maps to screen-down, so this
       becomes a correctly downward-pointing arrowhead.
       refX=10, refY=5 places the TIP at the line endpoint. -->
  <marker id=""arrDown"" viewBox=""0 0 10 10"" refX=""10"" refY=""5""
          markerWidth=""10"" markerHeight=""10"" orient=""auto"">
    <polygon points=""0 0, 10 5, 0 10"" fill=""#333""/>
  </marker>
</defs>
";

        private static string DownArrow(int cx, int y1, int y2)
        {
            return $"<line x1=\"{cx}\" y1=\"{y1}\" x2=\"{cx}\" y2=\"{y2}\" stroke=\"#111\" stroke-width=\"1.6\" marker-end=\"url(#arrDown)\"/>\n";
        }

        // Attacker Network block: dashed container, hooded-figure monitor, sub-label.
        private static string AttackerBlock(int x, int y)
        {
            int w = AttackerW, h = AttackerH;
            var sb = new StringBuilder();
            sb.Append($"<g>");
            sb.Append($"<rect x=\"{x}\" y=\"{y}\" width=\"{w}\" height=\"{h}\" fill=\"none\" stroke=\"#333\" stroke-width=\"1.4\" stroke-dasharray=\"4,3\"/>");
            sb.Append($"<text x=\"{x + w / 2}\" y=\"{y + 22}\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"700\" fill=\"#111\">Attacker Network</text>");

            // Hooded-figure monitor icon centered horizontally, near top of the box.
            int ix = x + (w - 100) / 2;
            int iy = y + 38;
            sb.Append($"<g transform=\"translate({ix},{iy})\">");
            // Monitor bezel + screen
            sb.Append("<rect x=\"0\" y=\"20\" width=\"100\" height=\"70\" rx=\"4\" fill=\"#e6f2fb\" stroke=\"#111\" stroke-width=\"1.2\"/>");
            sb.Append("<rect x=\"5\" y=\"25\" width=\"90\" height=\"55\" fill=\"#ffffff\" stroke=\"#111\" stroke-width=\"0.6\"/>");
            // Hood
            sb.Append("<path d=\"M 34 12 Q 34 -2 50 -2 Q 66 -2 66 12 L 66 30 L 34 30 Z\" fill=\"#111\" stroke=\"#111\"/>");
            // Eyes strip
            sb.Append("<rect x=\"42\" y=\"16\" width=\"16\" height=\"6\" fill=\"#e6f2fb\"/>");
            // Shoulders under screen
            sb.Append("<path d=\"M 30 30 Q 30 44 40 48 L 60 48 Q 70 44 70 30 Z\" fill=\"#111\"/>");
            // Stand + base
            sb.Append("<rect x=\"45\" y=\"90\" width=\"10\" height=\"6\" fill=\"#111\"/>");
            sb.Append("<rect x=\"30\" y=\"96\" width=\"40\" height=\"4\" rx=\"1\" fill=\"#111\"/>");
            sb.Append("</g>");

            // Sub-label
            sb.Append($"<text x=\"{x + w / 2}\" y=\"{y + h - 24}\" text-anchor=\"middle\" font-size=\"12\" fill=\"#111\">VDI</text>");
            sb.Append($"<text x=\"{x + w / 2}\" y=\"{y + h - 10}\" text-anchor=\"middle\" font-size=\"12\" fill=\"#111\">Infrastructure</text>");
            sb.Append($"</g>\n");
            return sb.ToString();
        }

        // Cisco cylinder router — clean body only, no coloured diagonal arrow shapes.
        private static string CiscoRouter(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            sb.Append("<rect x=\"0\" y=\"16\" width=\"100\" height=\"28\" fill=\"#2ea3c9\"/>");
            sb.Append("<ellipse cx=\"50\" cy=\"44\" rx=\"50\" ry=\"12\" fill=\"#1f80a3\"/>");
            sb.Append("<ellipse cx=\"50\" cy=\"16\" rx=\"50\" ry=\"12\" fill=\"#2ea3c9\"/>");
            sb.Append("<ellipse cx=\"50\" cy=\"16\" rx=\"50\" ry=\"12\" fill=\"none\" stroke=\"#9be3f5\" stroke-width=\"1\" opacity=\"0.8\"/>");
            sb.Append("</g>\n");
            return sb.ToString();
        }

        // One dashed sub-environment box with a header bar and a grid of devices.
        private static string SubEnvBox(int x, int y, int w, int h, string label, List<Box> hosts)
        {
            var sb = new StringBuilder();
            // Container (dashed)
            sb.Append($"<g>");
            sb.Append($"<rect x=\"{x}\" y=\"{y}\" width=\"{w}\" height=\"{h}\" fill=\"none\" stroke=\"#333\" stroke-width=\"1.2\" stroke-dasharray=\"4,3\"/>");
            // Header bar (solid rectangle around the title, no fill)
            sb.Append($"<rect x=\"{x}\" y=\"{y}\" width=\"{w}\" height=\"{SubBoxHeaderH}\" fill=\"none\" stroke=\"#333\" stroke-width=\"1\"/>");
            sb.Append($"<text x=\"{x + w / 2}\" y=\"{y + 20}\" text-anchor=\"middle\" font-size=\"13\" font-weight=\"700\" fill=\"#111\">{XmlEscape(label)}</text>");
            sb.Append($"</g>\n");

            // Device grid inside sub-box
            int gridX = x + SubBoxPadX;
            int gridY = y + SubBoxHeaderH + SubBoxPadY;
            int gridInnerW = w - 2 * SubBoxPadX;
            int cellSpanW = gridInnerW / DevPerRow;         // cell horizontal slot (label may span slightly)

            for (int i = 0; i < hosts.Count; i++)
            {
                int row = i / DevPerRow;
                int col = i % DevPerRow;
                int cellCx = gridX + col * cellSpanW + cellSpanW / 2;
                int cellTopY = gridY + row * CellH;
                sb.Append(DeviceCell(cellCx, cellTopY, hosts[i]));
            }
            return sb.ToString();
        }

        // A single device cell. cx = horizontal centre; top = top y.
        // Shows OS-specific monitor icon + IP address only (no hostname notes).
        private static string DeviceCell(int cx, int top, Box b)
        {
            int ix = cx - IconW / 2;
            var sb = new StringBuilder();
            sb.Append($"<g>");
            sb.Append(IsWindows(b)
                ? WinTileMonitor(ix, top)
                : LinuxMonitor(ix, top));
            int labelY = top + IconH + 18;
            sb.Append($"<text x=\"{cx}\" y=\"{labelY}\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"700\" fill=\"#111\">{XmlEscape(b.Ip ?? "")}</text>");
            sb.Append($"</g>\n");
            return sb.ToString();
        }

        // ==================== device icons ====================

        // Windows monitor: bezel + white screen + 4-colour Windows flag.
        private static string WinTileMonitor(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            sb.Append("<rect x=\"0\" y=\"0\" width=\"52\" height=\"45\" rx=\"3\" fill=\"#e8f4fb\" stroke=\"#2c7bb6\" stroke-width=\"1.4\"/>");
            sb.Append("<rect x=\"3\" y=\"3\" width=\"46\" height=\"34\" fill=\"#ffffff\"/>");
            // 4-colour Windows flag in screen
            sb.Append("<path d=\"M 6 7 L 23 5 L 23 19 L 6 21 Z\" fill=\"#f25022\"/>");
            sb.Append("<path d=\"M 25 5 L 46 3 L 46 19 L 25 19 Z\" fill=\"#7fba00\"/>");
            sb.Append("<path d=\"M 6 23 L 23 21 L 23 35 L 6 37 Z\" fill=\"#00a4ef\"/>");
            sb.Append("<path d=\"M 25 21 L 46 19 L 46 35 L 25 35 Z\" fill=\"#ffb900\"/>");
            // Stand
            sb.Append("<rect x=\"22\" y=\"45\" width=\"8\" height=\"5\" fill=\"#2c7bb6\"/>");
            sb.Append("<rect x=\"14\" y=\"50\" width=\"24\" height=\"3\" rx=\"1\" fill=\"#2c7bb6\"/>");
            sb.Append("</g>");
            return sb.ToString();
        }

        // Linux monitor: bezel + white screen + simplified Tux penguin.
        private static string LinuxMonitor(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            // Bezel + screen
            sb.Append("<rect x=\"0\" y=\"0\" width=\"52\" height=\"45\" rx=\"3\" fill=\"#e8f4fb\" stroke=\"#2c7bb6\" stroke-width=\"1.4\"/>");
            sb.Append("<rect x=\"3\" y=\"3\" width=\"46\" height=\"34\" fill=\"#ffffff\"/>");
            // Tux penguin centred in screen (screen centre: 26, 20)
            sb.Append("<ellipse cx=\"26\" cy=\"26\" rx=\"9\" ry=\"12\" fill=\"#111\"/>"); // body
            sb.Append("<ellipse cx=\"26\" cy=\"28\" rx=\"5\" ry=\"8\" fill=\"#f5f5f5\"/>"); // belly
            sb.Append("<ellipse cx=\"26\" cy=\"11\" rx=\"7\" ry=\"6\" fill=\"#111\"/>"); // head
            sb.Append("<circle cx=\"22\" cy=\"10\" r=\"2\" fill=\"white\"/>"); // L eye white
            sb.Append("<circle cx=\"30\" cy=\"10\" r=\"2\" fill=\"white\"/>"); // R eye white
            sb.Append("<circle cx=\"22\" cy=\"10\" r=\"1\" fill=\"#222\"/>"); // L pupil
            sb.Append("<circle cx=\"30\" cy=\"10\" r=\"1\" fill=\"#222\"/>"); // R pupil
            sb.Append("<path d=\"M 23 15 L 29 15 L 26 19 Z\" fill=\"#e8a000\"/>"); // beak
            // Stand
            sb.Append("<rect x=\"22\" y=\"45\" width=\"8\" height=\"5\" fill=\"#2c7bb6\"/>");
            sb.Append("<rect x=\"14\" y=\"50\" width=\"24\" height=\"3\" rx=\"1\" fill=\"#2c7bb6\"/>");
            sb.Append("</g>");
            return sb.ToString();
        }

        // ==================== helpers ====================

        private static string XmlEscape(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("&", "&amp;").Replace("<", "&lt;")
                    .Replace(">", "&gt;").Replace("\"", "&quot;")
                    .Replace("'", "&apos;");
        }

        private static string Ellipsize(string s, int max) =>
            (s?.Length ?? 0) <= max ? (s ?? "") : s.Substring(0, max - 1) + "…";

        // ==================== draw.io export ====================
        //
        // draw.io doesn't have a good match for our custom hand-drawn icons, so
        // we settle for the same *layout* using built-in mxgraph stencils:
        // attacker card at top, cisco router below, outer swimlane containing
        // per-subnet swimlanes with device icons.

        public static byte[] RenderDrawio(List<Box> boxes)
        {
            var grouped = GroupBySubnet(boxes);
            var layout = Compute(grouped);

            var ms = new MemoryStream();
            var settings = new XmlWriterSettings
            {
                OmitXmlDeclaration = true,
                Indent = true,
                Encoding = new UTF8Encoding(false),
            };
            using (var w = XmlWriter.Create(ms, settings))
            {
                w.WriteStartElement("mxfile");
                w.WriteAttributeString("host", "app.diagrams.net");
                w.WriteStartElement("diagram");
                w.WriteAttributeString("id", "jvision-topology");
                w.WriteAttributeString("name", "Topology");
                w.WriteStartElement("mxGraphModel");
                w.WriteAttributeString("dx", "1200");
                w.WriteAttributeString("dy", "800");
                w.WriteAttributeString("grid", "1");
                w.WriteAttributeString("gridSize", "10");
                w.WriteAttributeString("pageWidth", layout.CanvasW.ToString(CultureInfo.InvariantCulture));
                w.WriteAttributeString("pageHeight", layout.CanvasH.ToString(CultureInfo.InvariantCulture));
                w.WriteStartElement("root");

                DrawioCell(w, "0", null, null, null);
                DrawioCell(w, "1", "0", null, null);

                // Attacker box (dashed swimlane)
                DrawioVertex(w, "attacker", "1", "Attacker Network",
                    "swimlane;html=1;fontStyle=1;startSize=26;fillColor=none;strokeColor=#333333;strokeWidth=1.4;dashed=1;dashPattern=4 3;fontColor=#111111;fontSize=13;",
                    layout.AttackerX, AttackerTopY, AttackerW, AttackerH);

                // Router (cyan)
                DrawioVertex(w, "router", "1", "ROUTER",
                    "shape=mxgraph.cisco.routers.router;html=1;fillColor=#2ea3c9;strokeColor=#1f80a3;fontColor=#111111;fontStyle=1;labelPosition=right;verticalLabelPosition=middle;align=left;verticalAlign=middle;",
                    layout.RouterX, RouterTopY, RouterW, RouterH);

                // Edges attacker -> router -> subnet area
                DrawioEdge(w, "e1", "1", "attacker", "router", downArrow: true);

                // Sub-environments and their hosts
                for (int i = 0; i < grouped.Count; i++)
                {
                    var (subnet, hosts) = grouped[i];
                    var (x, y, sw, sh) = layout.SubBoxes[i];
                    string subId = $"sub_{i}";
                    // draw.io swimlane coords are absolute for top-level children of "1".
                    DrawioVertex(w, subId, "1", subnet,
                        "swimlane;html=1;fontStyle=1;startSize=26;fillColor=none;strokeColor=#333333;strokeWidth=1.2;dashed=1;dashPattern=4 3;fontColor=#111111;fontSize=12;",
                        x, y, sw, sh);

                    int gridX = SubBoxPadX;
                    int gridY = SubBoxHeaderH + SubBoxPadY;
                    int gridInnerW = sw - 2 * SubBoxPadX;
                    int cellSpanW = gridInnerW / DevPerRow;
                    for (int hIdx = 0; hIdx < hosts.Count; hIdx++)
                    {
                        var host = hosts[hIdx];
                        int row = hIdx / DevPerRow;
                        int col = hIdx % DevPerRow;
                        int hx = gridX + col * cellSpanW + (cellSpanW - IconW) / 2;
                        int hy = gridY + row * CellH;
                        string hostname = string.IsNullOrEmpty(host.Hostname) ? "" : host.Hostname;
                        string label = (host.Ip ?? "") + (string.IsNullOrEmpty(hostname) ? "" : "<br>" + hostname);
                        string style = IsWindows(host)
                            ? "shape=mxgraph.mscae/computer;html=1;fillColor=#2261c4;strokeColor=#1e3a8a;labelPosition=center;verticalLabelPosition=bottom;align=center;verticalAlign=top;fontSize=11;fontStyle=1;fontColor=#111111;"
                            : "shape=mxgraph.networks/pc;html=1;fillColor=#2261c4;strokeColor=#1e3a8a;labelPosition=center;verticalLabelPosition=bottom;align=center;verticalAlign=top;fontSize=11;fontStyle=1;fontColor=#111111;";
                        DrawioVertex(w, $"h_{i}_{hIdx}", subId, label, style, hx, hy, IconW, IconH);
                    }
                }

                w.WriteEndElement();  // root
                w.WriteEndElement();  // mxGraphModel
                w.WriteEndElement();  // diagram
                w.WriteEndElement();  // mxfile
            }
            return ms.ToArray();
        }

        private static void DrawioCell(XmlWriter w, string id, string parent, string value, string style)
        {
            w.WriteStartElement("mxCell");
            w.WriteAttributeString("id", id);
            if (value != null) w.WriteAttributeString("value", value);
            if (style != null) w.WriteAttributeString("style", style);
            if (parent != null) w.WriteAttributeString("parent", parent);
            w.WriteEndElement();
        }

        private static void DrawioVertex(XmlWriter w, string id, string parent, string value, string style, int x, int y, int width, int height)
        {
            w.WriteStartElement("mxCell");
            w.WriteAttributeString("id", id);
            w.WriteAttributeString("value", value ?? "");
            w.WriteAttributeString("style", style);
            w.WriteAttributeString("vertex", "1");
            w.WriteAttributeString("parent", parent);
            w.WriteStartElement("mxGeometry");
            w.WriteAttributeString("x", x.ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("y", y.ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("width", width.ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("height", height.ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("as", "geometry");
            w.WriteEndElement();
            w.WriteEndElement();
        }

        private static void DrawioEdge(XmlWriter w, string id, string parent, string source, string target, bool downArrow)
        {
            w.WriteStartElement("mxCell");
            w.WriteAttributeString("id", id);
            w.WriteAttributeString("style",
                downArrow
                    ? "endArrow=classic;startArrow=none;html=1;strokeColor=#111111;strokeWidth=1.6;"
                    : "endArrow=classic;startArrow=classic;html=1;strokeColor=#111111;strokeWidth=1.6;");
            w.WriteAttributeString("edge", "1");
            w.WriteAttributeString("parent", parent);
            w.WriteAttributeString("source", source);
            w.WriteAttributeString("target", target);
            w.WriteStartElement("mxGeometry");
            w.WriteAttributeString("relative", "1");
            w.WriteAttributeString("as", "geometry");
            w.WriteEndElement();
            w.WriteEndElement();
        }
    }
}
