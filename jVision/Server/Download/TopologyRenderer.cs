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
    // "APT report" topology renderer -- mimics the reference layout used in
    // typical pentest report figures (see network top/ WhatsApp Image ...):
    //
    //   +--------------------------+
    //   |     Attacker Network     |   dashed box, hooded-figure monitor
    //   +--------------------------+
    //              |
    //              v
    //          [ CISCO ]              cyan cylinder with 4 radiating arrows
    //          [ ROUTER]  <subnets>
    //              |
    //              v
    //   +--------------------------+
    //   | Production Network       |   big outer dashed frame
    //   |  +-----------+ +-------+ |
    //   |  | subnet A  | | sub B | |   one dashed sub-box per unique subnet
    //   |  |  [W][W][W]| |  [L]  | |   Windows tile / Linux globe monitors
    //   |  +-----------+ +-------+ |   IP bold + hostname below each device
    //   +--------------------------+
    //
    // Mapping from jVision data:
    //   Box.Subnet   -> sub-environment label (one sub-box per distinct value)
    //   Box.Hostname -> shown under IP
    //   Box.Ip       -> bold label
    //   Box.Os       -> icon selector ("windows" -> tile, else -> globe)
    public static class TopologyRenderer
    {
        // ---- Layout constants (kept close to the option4 mockup) ----
        private const int CanvasMinW = 1220;
        private const int OuterPadX = 40;

        private const int AttackerW = 200, AttackerH = 180;
        private const int AttackerTopY = 30;

        private const int RouterW = 100, RouterH = 60;
        private const int RouterTopY = 285;

        private const int OuterFrameTopY = 420;
        private const int OuterFramePad = 30;              // gap inside outer frame

        // Sub-environment box
        private const int SubBoxMinW = 380;
        private const int SubBoxHeaderH = 30;
        private const int SubBoxPadX = 20, SubBoxPadY = 20;

        // Device cell (icon + labels)
        private const int IconW = 60, IconH = 52;
        private const int CellW = 170, CellH = 130;        // includes label area
        private const int DevPerRow = 3;

        private const int SubGapX = 20, SubGapY = 20;
        private const int SubCols = 2;                     // subnets per row inside outer frame

        // ==================== data grouping ====================

        private static Version TryParseIp(string ip) =>
            Version.TryParse(ip ?? "", out var v) ? v : new Version(0, 0, 0, 0);

        private static List<(string Subnet, List<Box> Hosts)> GroupBySubnet(List<Box> boxes)
        {
            return boxes
                .GroupBy(b => string.IsNullOrEmpty(b.Subnet) ? "(no subnet)" : b.Subnet)
                .OrderByDescending(g => g.Count())          // biggest first (best fit for 2-col grid)
                .ThenBy(g => g.Key, StringComparer.Ordinal)
                .Select(g => (g.Key, g.OrderBy(b => TryParseIp(b.Ip)).ToList()))
                .ToList();
        }

        private static bool IsWindows(Box b) =>
            (b.Os ?? "").ToLowerInvariant().Contains("windows");

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

            // Header text: aggregate subnet CIDRs for the outer frame + router label
            var subnetLabels = grouped.Select(g => g.Subnet).ToList();
            string outerTitle = subnetLabels.Count == 0
                ? "Production Network"
                : "Production Network — " + string.Join(" · ", subnetLabels);
            string routerLabel = subnetLabels.Count == 0 ? "" : string.Join(", ", subnetLabels);

            var sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n");
            sb.Append($"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{layout.CanvasW}\" height=\"{layout.CanvasH}\" viewBox=\"0 0 {layout.CanvasW} {layout.CanvasH}\" font-family=\"Arial, Helvetica, sans-serif\">\n");
            sb.Append(Defs());
            sb.Append($"<rect width=\"{layout.CanvasW}\" height=\"{layout.CanvasH}\" fill=\"#ffffff\"/>\n");

            // Attacker Network
            sb.Append(AttackerBlock(layout.AttackerX, AttackerTopY));

            // Arrow attacker -> router
            sb.Append(DownArrow(layout.CanvasW / 2, AttackerTopY + AttackerH + 10, RouterTopY - 8));

            // Router
            sb.Append(CiscoRouter(layout.RouterX, RouterTopY));
            if (!string.IsNullOrEmpty(routerLabel))
            {
                sb.Append($"<text x=\"{layout.RouterX + RouterW + 20}\" y=\"{RouterTopY + RouterH / 2 + 5}\" font-size=\"14\" font-weight=\"700\" fill=\"#111\">{XmlEscape(routerLabel)}</text>\n");
            }

            // Arrow router -> outer frame
            sb.Append(DownArrow(layout.CanvasW / 2, RouterTopY + RouterH + 20, layout.OuterFrameY - 8));

            // Outer frame title (floats just above the frame)
            sb.Append($"<text x=\"{layout.OuterFrameX}\" y=\"{layout.OuterFrameY - 6}\" font-size=\"15\" font-weight=\"700\" fill=\"#111\">{XmlEscape(outerTitle)}</text>\n");

            // Outer frame rectangle (dashed)
            sb.Append($"<rect x=\"{layout.OuterFrameX}\" y=\"{layout.OuterFrameY}\" width=\"{layout.OuterFrameW}\" height=\"{layout.OuterFrameH}\" fill=\"none\" stroke=\"#333\" stroke-width=\"1.4\" stroke-dasharray=\"4,3\"/>\n");

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
<marker id=""arrDown"" viewBox=""0 0 10 10"" refX=""5"" refY=""9"" markerWidth=""10"" markerHeight=""10"" orient=""auto"">
  <path d=""M 0 0 L 10 0 L 5 10 z"" fill=""#111""/>
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

        // Cisco cylinder router with 4 diagonal colored arrows.
        private static string CiscoRouter(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            // TL green
            sb.Append("<path d=\"M 22 22 L 2 2 L -8 12 L 10 30 Z\" fill=\"#2e9c47\"/>");
            sb.Append("<path d=\"M 2 2 L -6 -4 L -2 -12 L 8 -6 Z\" fill=\"#2e9c47\"/>");
            // TR yellow
            sb.Append("<path d=\"M 78 22 L 98 2 L 108 12 L 90 30 Z\" fill=\"#f0a91d\"/>");
            sb.Append("<path d=\"M 98 2 L 106 -4 L 102 -12 L 92 -6 Z\" fill=\"#f0a91d\"/>");
            // BL blue
            sb.Append("<path d=\"M 22 40 L 2 60 L -8 50 L 10 32 Z\" fill=\"#2261c4\"/>");
            sb.Append("<path d=\"M 2 60 L -6 66 L -2 74 L 8 68 Z\" fill=\"#2261c4\"/>");
            // BR red
            sb.Append("<path d=\"M 78 40 L 98 60 L 108 50 L 90 32 Z\" fill=\"#c62727\"/>");
            sb.Append("<path d=\"M 98 60 L 106 66 L 102 74 L 92 68 Z\" fill=\"#c62727\"/>");
            // Cylinder body
            sb.Append("<ellipse cx=\"50\" cy=\"16\" rx=\"50\" ry=\"12\" fill=\"#2ea3c9\"/>");
            sb.Append("<rect x=\"0\" y=\"16\" width=\"100\" height=\"30\" fill=\"#2ea3c9\"/>");
            sb.Append("<ellipse cx=\"50\" cy=\"46\" rx=\"50\" ry=\"12\" fill=\"#1f80a3\"/>");
            sb.Append("<ellipse cx=\"50\" cy=\"16\" rx=\"50\" ry=\"12\" fill=\"none\" stroke=\"#9be3f5\" stroke-width=\"1\" opacity=\"0.7\"/>");
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

        // A single device cell. cx = horizontal center of the cell; top = top y.
        private static string DeviceCell(int cx, int top, Box b)
        {
            int ix = cx - IconW / 2;
            int iy = top;
            var sb = new StringBuilder();
            sb.Append($"<g>");
            sb.Append(IsWindows(b)
                ? WinTileMonitor(ix, iy)
                : GlobeMonitor(ix, iy));

            // IP bold on top, hostname underneath.
            int labelY = iy + IconH + 26;                   // icon 52 + stand ~10 + gap
            string hostname = string.IsNullOrEmpty(b.Hostname) ? "" : b.Hostname;
            sb.Append($"<text x=\"{cx}\" y=\"{labelY}\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"700\" fill=\"#111\">{XmlEscape(b.Ip ?? "")}</text>");
            if (!string.IsNullOrEmpty(hostname))
            {
                sb.Append($"<text x=\"{cx}\" y=\"{labelY + 14}\" text-anchor=\"middle\" font-size=\"11\" fill=\"#111\">{XmlEscape(Ellipsize(hostname, 26))}</text>");
            }
            sb.Append($"</g>\n");
            return sb.ToString();
        }

        // ==================== device icons ====================

        // Windows-tile monitor: cyan bezel + white screen + 4 blue tiles.
        private static string WinTileMonitor(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            sb.Append("<rect x=\"0\" y=\"0\" width=\"60\" height=\"52\" rx=\"4\" fill=\"#e6f2fb\" stroke=\"#2261c4\" stroke-width=\"1.4\"/>");
            sb.Append("<rect x=\"4\" y=\"4\" width=\"52\" height=\"44\" fill=\"#ffffff\" stroke=\"#2261c4\" stroke-width=\"1\"/>");
            // 4 blue tiles with slight bottom skew (Win logo perspective)
            sb.Append("<g transform=\"translate(16,10)\">");
            sb.Append("<path d=\"M 0 2 L 12 0 L 12 12 L 0 13 Z\" fill=\"#2261c4\"/>");
            sb.Append("<path d=\"M 14 0 L 28 -2 L 28 12 L 14 12 Z\" fill=\"#2261c4\"/>");
            sb.Append("<path d=\"M 0 15 L 12 14 L 12 26 L 0 27 Z\" fill=\"#2261c4\"/>");
            sb.Append("<path d=\"M 14 14 L 28 12 L 28 26 L 14 26 Z\" fill=\"#2261c4\"/>");
            sb.Append("</g>");
            // Stand
            sb.Append("<rect x=\"26\" y=\"52\" width=\"8\" height=\"6\" fill=\"#2261c4\"/>");
            sb.Append("<rect x=\"16\" y=\"58\" width=\"28\" height=\"4\" rx=\"1\" fill=\"#2261c4\"/>");
            sb.Append("</g>");
            return sb.ToString();
        }

        // Globe monitor: cyan bezel + white screen + blue globe glyph with cursor.
        private static string GlobeMonitor(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            sb.Append("<rect x=\"0\" y=\"0\" width=\"60\" height=\"52\" rx=\"4\" fill=\"#e6f2fb\" stroke=\"#2261c4\" stroke-width=\"1.4\"/>");
            sb.Append("<rect x=\"4\" y=\"4\" width=\"52\" height=\"44\" fill=\"#ffffff\" stroke=\"#2261c4\" stroke-width=\"1\"/>");
            // Globe (meridians + equator + oval hints)
            sb.Append("<g transform=\"translate(30,26)\" stroke=\"#2261c4\" stroke-width=\"1.6\" fill=\"none\">");
            sb.Append("<circle r=\"14\"/>");
            sb.Append("<line x1=\"-14\" y1=\"0\" x2=\"14\" y2=\"0\"/>");
            sb.Append("<line x1=\"0\" y1=\"-14\" x2=\"0\" y2=\"14\"/>");
            sb.Append("<ellipse cx=\"0\" cy=\"0\" rx=\"7\" ry=\"14\"/>");
            sb.Append("<ellipse cx=\"0\" cy=\"0\" rx=\"14\" ry=\"6\"/>");
            sb.Append("</g>");
            // Small cursor arrow overlay
            sb.Append("<path d=\"M 40 30 L 46 34 L 43 36 L 46 42 L 43 43 L 40 37 L 37 40 Z\" fill=\"#2261c4\"/>");
            // Stand
            sb.Append("<rect x=\"26\" y=\"52\" width=\"8\" height=\"6\" fill=\"#2261c4\"/>");
            sb.Append("<rect x=\"16\" y=\"58\" width=\"28\" height=\"4\" rx=\"1\" fill=\"#2261c4\"/>");
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

                // Edges attacker -> router -> outer
                DrawioEdge(w, "e1", "1", "attacker", "router", downArrow: true);

                // Outer frame (Production Network)
                var subnetLabels = grouped.Select(g => g.Subnet).ToList();
                string outerTitle = subnetLabels.Count == 0
                    ? "Production Network"
                    : "Production Network — " + string.Join(" · ", subnetLabels);
                DrawioVertex(w, "outer", "1", outerTitle,
                    "swimlane;html=1;fontStyle=1;startSize=28;fillColor=none;strokeColor=#333333;strokeWidth=1.4;dashed=1;dashPattern=4 3;fontColor=#111111;fontSize=14;verticalAlign=top;align=left;spacingLeft=12;",
                    layout.OuterFrameX, layout.OuterFrameY, layout.OuterFrameW, layout.OuterFrameH);
                DrawioEdge(w, "e2", "1", "router", "outer", downArrow: true);

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
