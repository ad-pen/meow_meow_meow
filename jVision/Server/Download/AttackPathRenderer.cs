using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using jVision.Server.Models;
using jVision.Shared.Models;

namespace jVision.Server.Download
{
    // Dedicated "attack-narrative map" renderer, meant for the report page —
    // NOT overlaid on the network topology. Every recorded PivotEdge becomes
    // a numbered step in a top-down tree, so the reader can follow the kill
    // chain by step number without decoding IP layouts.
    //
    // Structure:
    //     ATTACKER (hooded monitor icon)
    //        │  initial access
    //        ▼
    //     [ first foothold(s) ]
    //        │  (1) exploit: CVE-…
    //        ▼
    //     [ next hop ]
    //        │  (2) creds: user:pass
    //        ▼
    //        …
    //
    // Steps are numbered by PivotEdge.CreatedAt so the numbers match the order
    // the operator captured them. If the pivot graph branches (one source
    // reached two targets) the tree layout centers each subtree independently
    // — the classic Reingold–Tilford-lite algorithm.
    public static class AttackPathRenderer
    {
        // --- layout constants --------------------------------------------------
        // Horizontal (left→right) kill-chain layout. Attacker sits on the far
        // left, each successive hop is one card-column further right, and any
        // branches (one source pivoting to N targets) stack vertically inside
        // the same column.
        private const int NodeW = 110;
        private const int NodeH = 100;
        private const int HStep = 130;   // horizontal spacing between hop levels
        private const int VStep = 44;    // vertical spacing between sibling branches
        private const int PadX = 50;
        private const int PadY = 24;     // top/bottom breathing room around the tree
        private const int MinCanvasW = 640;
        private const int MinCanvasH = 200;

        private const int IconInsetX = (NodeW - 52) / 2;
        private const int IconInsetY = 10;
        private const int CornerRadius = 10;

        // Legend block sizing.
        private const int LegendTitleH = 40;
        private const int LegendRowH = 26;
        private const int LegendPadY = 24;
        private const int LegendLeftX = 60;
        private const int LegendColGap = 40;

        // Symbols legend box (bottom-right of the canvas).
        private const int SymbolLegendW = 230;
        private const int SymbolLegendH = 180;
        private const int SymbolBadgeVGap = 24;   // px above each arrow badge where the shape marker sits

        // --- render entry ------------------------------------------------------

        public static byte[] RenderSvg(List<Box> boxes, List<PivotEdge> edges)
        {
            var boxByIp = new Dictionary<string, Box>(StringComparer.OrdinalIgnoreCase);
            foreach (var b in boxes)
                if (!string.IsNullOrEmpty(b.Ip)) boxByIp[b.Ip] = b;

            var valid = (edges ?? new List<PivotEdge>())
                .Where(e => e != null
                            && !string.IsNullOrEmpty(e.SourceIp)
                            && !string.IsNullOrEmpty(e.TargetIp)
                            && !string.Equals(e.SourceIp, e.TargetIp, StringComparison.OrdinalIgnoreCase))
                .OrderBy(e => e.CreatedAt)
                .ToList();

            var attacker = new TreeNode { Label = "Attacker", IsAttacker = true };
            var tree = BuildTree(valid, boxByIp, attacker);
            LayoutTree(tree, PadX, PadY);

            // Walk the tree once to assign the display label ("★", "1", "A",
            // "3", ...) and path id ("shared" or the branch letter) to every
            // edge. This is what drives both the badges on the arrows and the
            // grouped rows in the legend below.
            AssignLabels(tree);

            // Group edges by path id for the legend. Shared prefix first, then
            // each branch as its own column.
            var sharedEdges = CollectEdgesByPath(tree, "shared");
            var branchPaths = new SortedDictionary<string, List<TreeEdge>>(StringComparer.Ordinal);
            CollectAllBranches(tree, branchPaths);
            int maxBranchRows = branchPaths.Count == 0 ? 0 : branchPaths.Values.Max(v => v.Count);

            int legendBlockH = 0;
            if (sharedEdges.Count + branchPaths.Values.Sum(v => v.Count) > 0)
            {
                int sharedBlockH = LegendTitleH + Math.Max(1, sharedEdges.Count) * LegendRowH + LegendPadY;
                int branchBlockH = branchPaths.Count > 0
                    ? LegendTitleH + Math.Max(1, maxBranchRows) * LegendRowH + LegendPadY
                    : 0;
                int symbolBlockH = SymbolLegendH + LegendPadY;
                legendBlockH = sharedBlockH + branchBlockH + symbolBlockH;
            }

            int canvasW = Math.Max(MinCanvasW, ComputeCanvasWidth(tree) + PadX);
            int canvasH = Math.Max(MinCanvasH, tree.SubtreeH + 2 * PadY) + legendBlockH;

            var sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n");
            sb.Append($"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{canvasW}\" height=\"{canvasH}\" viewBox=\"0 0 {canvasW} {canvasH}\" font-family=\"Arial, Helvetica, sans-serif\">\n");
            sb.Append(Defs());
            sb.Append($"<rect width=\"{canvasW}\" height=\"{canvasH}\" fill=\"#ffffff\"/>\n");

            if (valid.Count == 0)
            {
                sb.Append($"<text x=\"{canvasW / 2}\" y=\"{canvasH / 2}\" text-anchor=\"middle\" font-size=\"14\" fill=\"#94a3b8\">No pivots recorded yet.</text>\n");
                sb.Append("</svg>\n");
                return Encoding.UTF8.GetBytes(sb.ToString());
            }

            // Draw edges first so nodes sit on top of arrowheads.
            DrawEdges(sb, tree);
            DrawNodes(sb, tree);

            if (sharedEdges.Count + branchPaths.Values.Sum(v => v.Count) > 0)
            {
                int legendTopY = Math.Max(MinCanvasH, tree.SubtreeH + 2 * PadY);
                DrawLegend(sb, sharedEdges, branchPaths, canvasW, canvasH, legendTopY);
            }

            sb.Append("</svg>\n");
            return Encoding.UTF8.GetBytes(sb.ToString());
        }

        // Three-section legend:
        //   1. "Shared prefix"       — ★ + numbered edges before the first branch
        //   2. "Path A" | "Path B" … — one column per branch subtree, side by side
        //   3. "Techniques (symbol)" — boxed shape→technique key, bottom-right
        private static void DrawLegend(StringBuilder sb,
                                       List<TreeEdge> sharedEdges,
                                       SortedDictionary<string, List<TreeEdge>> branchPaths,
                                       int canvasW, int canvasH, int topY)
        {
            int y = topY;

            // 1) Shared prefix
            y = DrawLegendSection(sb, "Shared prefix", sharedEdges, LegendLeftX, canvasW - LegendLeftX, y);

            // 2) Side-by-side branch columns
            if (branchPaths.Count > 0)
            {
                int totalInner = canvasW - 2 * LegendLeftX;
                int columnW = (totalInner - LegendColGap * (branchPaths.Count - 1)) / branchPaths.Count;

                // Separator + column titles
                sb.Append(FormattableString.Invariant(
                    $"<line x1=\"{LegendLeftX}\" y1=\"{y}\" x2=\"{canvasW - LegendLeftX}\" y2=\"{y}\" stroke=\"#cbd5e1\" stroke-width=\"1\"/>\n"));

                int titleY = y + 26;
                int colIdx = 0;
                foreach (var kv in branchPaths)
                {
                    int colX = LegendLeftX + colIdx * (columnW + LegendColGap);
                    sb.Append(FormattableString.Invariant(
                        $"<text x=\"{colX}\" y=\"{titleY}\" font-size=\"15\" font-weight=\"700\" fill=\"#111\">Path {kv.Key}</text>\n"));
                    colIdx++;
                }

                int rowsBase = y + LegendTitleH + 4;
                colIdx = 0;
                int deepest = 0;
                foreach (var kv in branchPaths)
                {
                    int colX = LegendLeftX + colIdx * (columnW + LegendColGap);
                    int rowY = rowsBase;
                    foreach (var e in kv.Value)
                    {
                        DrawLegendRow(sb, colX, rowY, e, columnW);
                        rowY += LegendRowH;
                    }
                    if (rowY > deepest) deepest = rowY;
                    colIdx++;
                }
                y = deepest + LegendPadY - LegendRowH;
            }

            // 3) Techniques (symbol) legend — bottom-right corner
            DrawSymbolLegend(sb, canvasW - SymbolLegendW - LegendLeftX, canvasH - SymbolLegendH - 20);
        }

        // Draws a titled section: separator line + section header + one row
        // per edge. Returns the y-coordinate right below the last row so the
        // next section can stack.
        private static int DrawLegendSection(StringBuilder sb, string title, List<TreeEdge> edges,
                                             int leftX, int rightX, int topY)
        {
            sb.Append(FormattableString.Invariant(
                $"<line x1=\"{leftX}\" y1=\"{topY}\" x2=\"{rightX}\" y2=\"{topY}\" stroke=\"#cbd5e1\" stroke-width=\"1\"/>\n"));
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{leftX}\" y=\"{topY + 26}\" font-size=\"15\" font-weight=\"700\" fill=\"#111\">{XmlEscape(title)}</text>\n"));

            int rowY = topY + LegendTitleH + 4;
            int fullW = rightX - leftX;
            foreach (var e in edges)
            {
                DrawLegendRow(sb, leftX, rowY, e, fullW);
                rowY += LegendRowH;
            }
            return rowY + LegendPadY - LegendRowH;
        }

        // One legend row: badge (matching the arrow), colour-blind shape,
        // then "src → dst · technique · label" text. widthBudget is the
        // horizontal room the row has — long descriptions get ellipsised so
        // side-by-side columns never bleed into each other.
        private static void DrawLegendRow(StringBuilder sb, int leftX, int y, TreeEdge e, int widthBudget)
        {
            string tech = e.Pivot?.Technique;
            string colour = e.Pivot == null ? "#334155" : TechniqueColour(tech);
            int badgeCx = leftX + 11;
            int badgeCy = y + 8;
            int fontSize = (e.DisplayLabel?.Length ?? 1) >= 3 ? 9 : 12;
            sb.Append(FormattableString.Invariant(
                $"<circle cx=\"{badgeCx}\" cy=\"{badgeCy}\" r=\"11\" fill=\"{colour}\" stroke=\"#ffffff\" stroke-width=\"1.5\"/>\n"));
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{badgeCx}\" y=\"{badgeCy + 4}\" text-anchor=\"middle\" font-size=\"{fontSize}\" font-weight=\"800\" fill=\"#ffffff\">{XmlEscape(e.DisplayLabel ?? "")}</text>\n"));

            int shapeX = leftX + 34;
            if (!string.IsNullOrEmpty(tech))
                sb.Append(TechniqueSymbol(tech, shapeX, badgeCy, colour));

            int textX = leftX + 50;
            int textRoom = Math.Max(60, widthBudget - (textX - leftX) - 8);
            const int fs = 13;
            const double charW = fs * 0.58;

            string src, dst, techLabel, description;
            if (e.Pivot == null)
            {
                src = "attacker";
                dst = XmlEscape(e.Target?.Ip ?? "");
                techLabel = "";
                description = "initial access";
            }
            else
            {
                src = XmlEscape(e.Pivot.SourceIp ?? "");
                dst = XmlEscape(e.Pivot.TargetIp ?? "");
                techLabel = XmlEscape((e.Pivot.Technique ?? "other").Trim());
                description = XmlEscape((e.Pivot.Label ?? "").Trim());
            }

            // Assemble a plain-text version to measure length, then compose
            // the tspan-rich body separately so bold rendering isn't lost.
            string plain = $"{src} → {dst}";
            if (!string.IsNullOrEmpty(techLabel)) plain += "  ·  " + techLabel;
            if (!string.IsNullOrEmpty(description)) plain += "  ·  " + description;

            int maxChars = Math.Max(6, (int)Math.Floor(textRoom / charW));
            if (plain.Length > maxChars)
            {
                // Ellipsise the description first (usually the longest piece)
                int overflow = plain.Length - maxChars + 1;
                if (description.Length > overflow)
                    description = description.Substring(0, description.Length - overflow) + "…";
                else
                    description = description.Length > 0 ? "…" : "";
            }

            string body = $"{src} → {dst}";
            if (!string.IsNullOrEmpty(techLabel))
                body += $"  ·  <tspan font-weight=\"700\">{techLabel}</tspan>";
            if (!string.IsNullOrEmpty(description))
                body += "  ·  " + description;

            sb.Append(FormattableString.Invariant(
                $"<text x=\"{textX}\" y=\"{badgeCy + 5}\" font-size=\"{fs}\" fill=\"{colour}\">{body}</text>\n"));
        }

        // Boxed "shape → technique" key, positioned in the bottom-right of the
        // canvas. Matches the shapes drawn above each arrow badge.
        private static void DrawSymbolLegend(StringBuilder sb, int x, int y)
        {
            sb.Append(FormattableString.Invariant(
                $"<rect x=\"{x}\" y=\"{y}\" width=\"{SymbolLegendW}\" height=\"{SymbolLegendH}\" rx=\"8\" ry=\"8\" fill=\"#ffffff\" stroke=\"#94a3b8\" stroke-width=\"1\"/>\n"));
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{x + 14}\" y=\"{y + 22}\" font-size=\"14\" font-weight=\"700\" fill=\"#111\">Techniques (symbol)</text>\n"));

            string[] techs = { "creds", "exploit", "session", "relay", "rce", "phish" };
            int rowY = y + 46;
            foreach (var t in techs)
            {
                string col = TechniqueColour(t);
                sb.Append(TechniqueSymbol(t, x + 26, rowY, col));
                sb.Append(FormattableString.Invariant(
                    $"<text x=\"{x + 44}\" y=\"{rowY + 5}\" font-size=\"13\" font-weight=\"600\" fill=\"{col}\">{t}</text>\n"));
                rowY += 22;
            }
        }

        // --- tree construction -------------------------------------------------

        private class TreeNode
        {
            public string Ip;
            public string Label;         // display text (IP or "Attacker")
            public bool IsAttacker;
            public bool IsWindows;
            public int X;
            public int Y;
            public int SubtreeH;         // total vertical span of this subtree
            public List<TreeEdge> Children = new();
        }

        private class TreeEdge
        {
            public PivotEdge Pivot;      // null for the implicit attacker→foothold edge
            public int StepNumber;       // 1-based step # from CreatedAt order; 0 for initial access
            public TreeNode Target;
            // Display label shown inside the arrow badge: "★" for initial
            // access, "1"/"2"/... for the shared prefix, "A"/"B"/... for the
            // first edge into each branch, then per-branch numbering resumes.
            public string DisplayLabel;
            // "shared" until the first branch, then the branch letter ("A",
            // "B", ...) inherited by every edge downstream of that branch.
            public string PathId;
        }

        // Build a strict tree: each host is placed under the FIRST pivot that
        // targets it (creation order). Any host that appears as a source but
        // never as a target of an earlier pivot becomes a foothold — child of
        // the attacker node with an "initial access" edge.
        private static TreeNode BuildTree(List<PivotEdge> valid,
                                          Dictionary<string, Box> boxByIp,
                                          TreeNode attacker)
        {
            var nodesByIp = new Dictionary<string, TreeNode>(StringComparer.OrdinalIgnoreCase);
            TreeNode GetOrCreate(string ip)
            {
                if (nodesByIp.TryGetValue(ip, out var n)) return n;
                n = new TreeNode
                {
                    Ip = ip,
                    Label = ip,
                    IsWindows = boxByIp.TryGetValue(ip, out var b) && IsWindowsBox(b),
                };
                nodesByIp[ip] = n;
                return n;
            }

            // Track which hosts are already attached to a parent to avoid
            // creating duplicate subtrees when the graph isn't a strict tree.
            var attached = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            for (int i = 0; i < valid.Count; i++)
            {
                var e = valid[i];
                var srcNode = GetOrCreate(e.SourceIp);
                var dstNode = GetOrCreate(e.TargetIp);

                if (!attached.Contains(e.SourceIp))
                {
                    // First time we see this source — treat it as a foothold
                    // if nobody has pivoted to it yet.
                    attacker.Children.Add(new TreeEdge
                    {
                        Target = srcNode,
                        Pivot = null,
                        StepNumber = 0,   // pre-step (initial access)
                    });
                    attached.Add(e.SourceIp);
                }

                if (!attached.Contains(e.TargetIp))
                {
                    srcNode.Children.Add(new TreeEdge
                    {
                        Target = dstNode,
                        Pivot = e,
                        StepNumber = i + 1,
                    });
                    attached.Add(e.TargetIp);
                }
                // If the target IS already attached elsewhere in the tree we
                // silently drop this duplicate edge; MVP tree layout can't
                // represent cross-links cleanly. The step numbering still
                // reflects creation order for the edges we do render.
            }

            return attacker;
        }

        // --- step labelling ----------------------------------------------------
        //
        // Attacker→foothold edges get "★". The first branch node (source with
        // >1 children) turns its children's edges into letter labels A, B, C…
        // After the branch, each subtree continues numbering from
        // (sharedLen + 2) — so the very first "path A" step and the very first
        // "path B" step both read the same number, giving each branch its own
        // clean sequence. Nested branches (rare) fall back to a compound path
        // id like "A.a", "A.b" so their edges still read distinctly.
        private static void AssignLabels(TreeNode attacker)
        {
            foreach (var e in attacker.Children)
            {
                e.DisplayLabel = "★";
                e.PathId = "shared";
            }
            int sharedCount = 0;
            foreach (var e in attacker.Children)
                WalkShared(e.Target, ref sharedCount);
        }

        private static void WalkShared(TreeNode node, ref int sharedCount)
        {
            if (node.Children.Count == 0) return;
            if (node.Children.Count == 1)
            {
                var edge = node.Children[0];
                sharedCount++;
                edge.DisplayLabel = sharedCount.ToString(CultureInfo.InvariantCulture);
                edge.PathId = "shared";
                WalkShared(edge.Target, ref sharedCount);
                return;
            }
            // Branch! Sibling edges become "A", "B", ... and each subtree
            // numbers from sharedCount+2 onward.
            int subStart = sharedCount + 2;
            for (int i = 0; i < node.Children.Count; i++)
            {
                var edge = node.Children[i];
                string letter = ((char)('A' + i)).ToString();
                edge.DisplayLabel = letter;
                edge.PathId = letter;
                WalkBranch(edge.Target, subStart, letter);
            }
        }

        private static void WalkBranch(TreeNode node, int nextStep, string pathId)
        {
            if (node.Children.Count == 0) return;
            if (node.Children.Count == 1)
            {
                var edge = node.Children[0];
                edge.DisplayLabel = nextStep.ToString(CultureInfo.InvariantCulture);
                edge.PathId = pathId;
                WalkBranch(edge.Target, nextStep + 1, pathId);
                return;
            }
            // Nested branch — use lower-case letter suffix so nobody confuses
            // "A.a" with the top-level "A" branch.
            for (int i = 0; i < node.Children.Count; i++)
            {
                var edge = node.Children[i];
                string subId = pathId + "." + (char)('a' + i);
                edge.DisplayLabel = subId;
                edge.PathId = subId;
                WalkBranch(edge.Target, nextStep + 1, subId);
            }
        }

        // Collect every edge whose PathId matches, in DFS order.
        private static List<TreeEdge> CollectEdgesByPath(TreeNode root, string pathId)
        {
            var acc = new List<TreeEdge>();
            void Walk(TreeNode n)
            {
                foreach (var e in n.Children)
                {
                    if (string.Equals(e.PathId, pathId, StringComparison.Ordinal))
                        acc.Add(e);
                    Walk(e.Target);
                }
            }
            Walk(root);
            return acc;
        }

        // Collect every branch subtree (edges with PathId != "shared"), grouped
        // by path id. Ordered by path id so "A" precedes "B" precedes "A.a".
        private static void CollectAllBranches(TreeNode root, SortedDictionary<string, List<TreeEdge>> acc)
        {
            void Walk(TreeNode n)
            {
                foreach (var e in n.Children)
                {
                    if (!string.Equals(e.PathId, "shared", StringComparison.Ordinal) && e.PathId != null)
                    {
                        if (!acc.TryGetValue(e.PathId, out var list))
                            acc[e.PathId] = list = new List<TreeEdge>();
                        list.Add(e);
                    }
                    Walk(e.Target);
                }
            }
            Walk(root);
        }

        // --- tree layout (left→right, subtree-centering) -----------------------

        // Place `node` at column X = `x`, then recursively place each child
        // one column further right (x + NodeW + HStep). Sibling children stack
        // vertically starting at `startY`, separated by VStep, and the parent
        // ends up vertically centered over the vertical span of its children.
        private static void LayoutTree(TreeNode node, int x, int startY)
        {
            if (node.Children.Count == 0)
            {
                node.SubtreeH = NodeH;
                node.X = x;
                node.Y = startY;
                return;
            }

            int childY = startY;
            foreach (var child in node.Children)
            {
                LayoutTree(child.Target, x + NodeW + HStep, childY);
                childY += child.Target.SubtreeH + VStep;
            }
            int totalH = (childY - VStep) - startY;
            node.SubtreeH = Math.Max(NodeH, totalH);
            node.X = x;
            node.Y = startY + (node.SubtreeH - NodeH) / 2;
        }

        private static int ComputeCanvasWidth(TreeNode node)
        {
            int max = node.X + NodeW;
            foreach (var c in node.Children)
                max = Math.Max(max, ComputeCanvasWidth(c.Target));
            return max;
        }

        // --- SVG parts ---------------------------------------------------------

        private static string Defs()
        {
            var sb = new StringBuilder();
            sb.Append("<defs>\n");
            // Per-technique arrowhead markers so each edge can carry its own
            // colour without breaking rasterisers that don't support
            // context-stroke.
            foreach (var colour in new[] { "#c026d3", "#dc2626", "#ea580c", "#0d9488", "#7c3aed", "#ca8a04", "#334155", "#111111" })
            {
                var id = "ap_arr_" + colour.TrimStart('#');
                sb.Append($"  <marker id=\"{id}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"9\" markerHeight=\"9\" orient=\"auto\"><polygon points=\"0 0, 10 5, 0 10\" fill=\"{colour}\"/></marker>\n");
            }
            sb.Append("</defs>\n");
            return sb.ToString();
        }

        private static string ArrowMarker(string colour) => "ap_arr_" + colour.TrimStart('#');

        private static void DrawNodes(StringBuilder sb, TreeNode node)
        {
            DrawNode(sb, node);
            foreach (var c in node.Children)
                DrawNodes(sb, c.Target);
        }

        private static void DrawNode(StringBuilder sb, TreeNode n)
        {
            // Card background (rounded rect with subtle border)
            sb.Append(FormattableString.Invariant(
                $"<rect x=\"{n.X}\" y=\"{n.Y}\" width=\"{NodeW}\" height=\"{NodeH}\" rx=\"10\" ry=\"10\" fill=\"#ffffff\" stroke=\"#94a3b8\" stroke-width=\"1.2\"/>\n"));

            int iconX = n.X + IconInsetX;
            int iconY = n.Y + IconInsetY;
            if (n.IsAttacker)
                sb.Append(AttackerIcon(iconX, iconY));
            else if (n.IsWindows)
                sb.Append(WindowsIcon(iconX, iconY));
            else
                sb.Append(TuxIcon(iconX, iconY));

            // Label under the icon
            int labelY = n.Y + NodeH - 12;
            string label = n.IsAttacker ? "ATTACKER" : (n.Label ?? "");
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{n.X + NodeW / 2}\" y=\"{labelY}\" text-anchor=\"middle\" font-size=\"12\" font-weight=\"700\" fill=\"#111\">{XmlEscape(label)}</text>\n"));
        }

        private static void DrawEdges(StringBuilder sb, TreeNode node)
        {
            foreach (var c in node.Children)
            {
                DrawEdge(sb, node, c);
                DrawEdges(sb, c.Target);
            }
        }

        private static void DrawEdge(StringBuilder sb, TreeNode parent, TreeEdge edge)
        {
            var child = edge.Target;
            // Exit parent from right-middle, enter child at left-middle.
            int sx = parent.X + NodeW;
            int sy = parent.Y + NodeH / 2;
            int tx = child.X;
            int ty = child.Y + NodeH / 2;

            string colour = edge.Pivot == null ? "#334155" : TechniqueColour(edge.Pivot.Technique);
            string marker = ArrowMarker(colour);

            // Orthogonal S-path: right → up/down → right. For siblings placed
            // vertically off-axis we insert a small vertical jog through the
            // midpoint column so every arrow shares the same "channel" x.
            string path;
            int midX = (sx + tx) / 2;
            int r = CornerRadius;
            if (sy == ty)
            {
                // Straight horizontal — same row, no branch needed.
                path = FormattableString.Invariant($"M {sx} {sy} H {tx - 2}");
            }
            else
            {
                int dir = ty > sy ? 1 : -1;             // +1 = child sits below parent
                int seg1EndX = midX - r;
                int seg2StartY = sy + dir * r;
                int seg2EndY = ty - dir * r;
                int seg2StartX = midX + r;
                if (seg1EndX < sx + r) seg1EndX = sx + r;
                if (seg2StartX > tx - r) seg2StartX = tx - r;

                // Sweep flags for right-then-down vs right-then-up. In SVG's
                // y-down coord system, right→down is a clockwise (sweep=1)
                // turn, right→up is counterclockwise (sweep=0). Down→right and
                // up→right mirror.
                int sw1 = dir > 0 ? 1 : 0;   // right→down or right→up
                int sw2 = dir > 0 ? 0 : 1;   // down→right or up→right

                var pb = new StringBuilder();
                pb.Append(FormattableString.Invariant($"M {sx} {sy}"));
                pb.Append(FormattableString.Invariant($" H {seg1EndX}"));
                pb.Append(FormattableString.Invariant($" A {r} {r} 0 0 {sw1} {midX} {seg2StartY}"));
                pb.Append(FormattableString.Invariant($" V {seg2EndY}"));
                pb.Append(FormattableString.Invariant($" A {r} {r} 0 0 {sw2} {seg2StartX} {ty}"));
                pb.Append(FormattableString.Invariant($" H {tx - 2}"));
                path = pb.ToString();
            }
            sb.Append($"<path d=\"{path}\" fill=\"none\" stroke=\"{colour}\" stroke-width=\"2.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\" marker-end=\"url(#{marker})\"/>\n");

            // Badge (label from AssignLabels — number, letter, or ★) plus a
            // colour-blind shape marker floating a bit above so the reader can
            // identify the technique without relying on colour alone. The ★
            // initial-access edge has no Pivot/technique so the symbol call
            // returns empty for it.
            int badgeX = midX;
            int badgeY = ty;
            sb.Append(BuildStepBadge(badgeX, badgeY, edge.DisplayLabel ?? edge.StepNumber.ToString(CultureInfo.InvariantCulture), colour));
            sb.Append(TechniqueSymbol(edge.Pivot?.Technique, badgeX, badgeY - SymbolBadgeVGap, colour));
        }

        // Pill sizing helper — figures out the actual pill width for a label
        // (respecting a maximum width) and returns the final text after any
        // ellipsis truncation. Kept separate from BuildLabelPillFixed so the
        // caller can lay out sibling groups symmetrically.
        private static (int pillW, int pillH, string label) MeasurePill(string label, int maxPillW)
        {
            const int fontSize = 13;
            const int padX = 10;
            const int padY = 5;
            const double charW = fontSize * 0.58;
            int pillH = fontSize + 2 * padY + 2;
            if (string.IsNullOrEmpty(label)) return (0, pillH, "");
            int maxChars = Math.Max(3, (int)Math.Floor((maxPillW - 2 * padX) / charW));
            if (label.Length > maxChars) label = label.Substring(0, maxChars - 1) + "…";
            int textW = (int)Math.Ceiling(label.Length * charW);
            int pillW = textW + 2 * padX;
            return (pillW, pillH, label);
        }

        private static string BuildLabelPillFixed(int leftX, int cy, string label, string colour, int pillW, int pillH)
        {
            const int fontSize = 13;
            const int padX = 10;
            int rx = pillH / 2;
            var sb = new StringBuilder();
            sb.Append(FormattableString.Invariant(
                $"<rect x=\"{leftX}\" y=\"{cy - pillH / 2}\" width=\"{pillW}\" height=\"{pillH}\" rx=\"{rx}\" ry=\"{rx}\" fill=\"#ffffff\" stroke=\"{colour}\" stroke-width=\"1.4\"/>\n"));
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{leftX + padX}\" y=\"{cy + fontSize / 3}\" text-anchor=\"start\" font-size=\"{fontSize}\" font-weight=\"700\" fill=\"{colour}\">{XmlEscape(label)}</text>\n"));
            return sb.ToString();
        }

        private static string BuildStepBadge(int cx, int cy, string label, string colour)
        {
            // Compact labels ("A", "3") use the standard font; wider labels
            // ("A.a") shrink one step so they don't clip the badge outline.
            int r = 13;
            int fontSize = (label?.Length ?? 1) >= 3 ? 10 : 13;
            var sb = new StringBuilder();
            sb.Append(FormattableString.Invariant(
                $"<circle cx=\"{cx}\" cy=\"{cy}\" r=\"{r}\" fill=\"{colour}\" stroke=\"#ffffff\" stroke-width=\"2\"/>\n"));
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{cx}\" y=\"{cy + 4}\" text-anchor=\"middle\" font-size=\"{fontSize}\" font-weight=\"800\" fill=\"#ffffff\">{XmlEscape(label ?? "")}</text>\n"));
            return sb.ToString();
        }

        // Distinct silhouette per technique so colour-blind readers can tell
        // arrows apart even in monochrome. Called both above each arrow badge
        // and inside the "Techniques (symbol)" legend box.
        private static string TechniqueSymbol(string technique, int x, int y, string colour)
        {
            switch ((technique ?? "").ToLowerInvariant())
            {
                case "creds":
                    return FormattableString.Invariant($"<path transform=\"translate({x},{y})\" d=\"M 0 -6 L 6 0 L 0 6 L -6 0 Z\" fill=\"{colour}\"/>");
                case "exploit":
                    return FormattableString.Invariant($"<path transform=\"translate({x},{y})\" d=\"M 0 -6 L 6 5 L -6 5 Z\" fill=\"{colour}\"/>");
                case "session":
                    return FormattableString.Invariant($"<circle cx=\"{x}\" cy=\"{y}\" r=\"5\" fill=\"{colour}\"/>");
                case "relay":
                    return FormattableString.Invariant($"<rect x=\"{x - 5}\" y=\"{y - 5}\" width=\"10\" height=\"10\" fill=\"{colour}\"/>");
                case "rce":
                    return FormattableString.Invariant($"<line x1=\"{x - 5}\" y1=\"{y - 5}\" x2=\"{x + 5}\" y2=\"{y + 5}\" stroke=\"{colour}\" stroke-width=\"2.4\" stroke-linecap=\"round\"/>")
                         + FormattableString.Invariant($"<line x1=\"{x + 5}\" y1=\"{y - 5}\" x2=\"{x - 5}\" y2=\"{y + 5}\" stroke=\"{colour}\" stroke-width=\"2.4\" stroke-linecap=\"round\"/>");
                case "phish":
                    return FormattableString.Invariant($"<path transform=\"translate({x},{y})\" d=\"M -5 -3 L 0 -6 L 5 -3 L 5 3 L 0 6 L -5 3 Z\" fill=\"{colour}\"/>");
                default:
                    return "";
            }
        }

        private static string BuildLabelPill(int leftX, int cy, string label, string colour, int maxPillW = int.MaxValue)
        {
            const int fontSize = 13;
            const int padX = 10;
            const int padY = 5;
            const double charW = fontSize * 0.58;
            // Fit-to-width: if the naive pill would spill past maxPillW,
            // truncate the label with an ellipsis so we stay inside the
            // arrow's horizontal segment and never draw over the child icon.
            int maxChars = Math.Max(4, (int)Math.Floor((maxPillW - 2 * padX) / charW));
            if (label.Length > maxChars) label = label.Substring(0, maxChars - 1) + "…";
            int textW = (int)Math.Ceiling(label.Length * charW);
            int pillW = textW + 2 * padX;
            int pillH = fontSize + 2 * padY + 2;
            int rx = pillH / 2;
            var sb = new StringBuilder();
            sb.Append(FormattableString.Invariant(
                $"<rect x=\"{leftX}\" y=\"{cy - pillH / 2}\" width=\"{pillW}\" height=\"{pillH}\" rx=\"{rx}\" ry=\"{rx}\" fill=\"#ffffff\" stroke=\"{colour}\" stroke-width=\"1.4\"/>\n"));
            sb.Append(FormattableString.Invariant(
                $"<text x=\"{leftX + padX}\" y=\"{cy + fontSize / 3}\" text-anchor=\"start\" font-size=\"{fontSize}\" font-weight=\"700\" fill=\"{colour}\">{XmlEscape(label)}</text>\n"));
            return sb.ToString();
        }

        private static string FormatEdgeLabel(TreeEdge edge)
        {
            if (edge.Pivot == null) return "initial access";
            var pieces = new List<string>();
            if (!string.IsNullOrWhiteSpace(edge.Pivot.Technique) && edge.Pivot.Technique != "other")
                pieces.Add(edge.Pivot.Technique);
            if (!string.IsNullOrWhiteSpace(edge.Pivot.Label))
                pieces.Add(edge.Pivot.Label);
            return Ellipsize(string.Join(": ", pieces), 44);
        }

        private static string TechniqueColour(string t) => (t ?? "").ToLowerInvariant() switch
        {
            "creds"   => "#c026d3",
            "exploit" => "#dc2626",
            "rce"     => "#ea580c",
            "session" => "#0d9488",
            "relay"   => "#7c3aed",
            "phish"   => "#ca8a04",
            _         => "#334155",
        };

        // --- icons (reused visual language from TopologyRenderer) --------------

        // Base64-embedded Tux PNG in the 52x45 icon footprint, letterboxed so
        // the aspect ratio isn't squashed.
        private static string TuxIcon(int x, int y)
        {
            return FormattableString.Invariant(
                $"<image x=\"{x}\" y=\"{y}\" width=\"52\" height=\"45\" preserveAspectRatio=\"xMidYMid meet\" href=\"{TuxAsset.DataUrl}\"/>");
        }

        // Windows: the four-colour flag standalone (no monitor frame), sized
        // and positioned to visually balance Tux at the same 52x45 footprint.
        private static string WindowsIcon(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            // Slight vertical centring gap so the flag sits mid-cell
            sb.Append("<path d=\"M 6 8 L 25 5 L 25 22 L 6 24 Z\" fill=\"#f25022\"/>");
            sb.Append("<path d=\"M 27 5 L 47 3 L 47 22 L 27 22 Z\" fill=\"#7fba00\"/>");
            sb.Append("<path d=\"M 6 26 L 25 24 L 25 41 L 6 43 Z\" fill=\"#00a4ef\"/>");
            sb.Append("<path d=\"M 27 24 L 47 22 L 47 41 L 27 41 Z\" fill=\"#ffb900\"/>");
            sb.Append("</g>");
            return sb.ToString();
        }

        private static string AttackerIcon(int x, int y)
        {
            var sb = new StringBuilder();
            sb.Append($"<g transform=\"translate({x},{y})\">");
            sb.Append("<rect x=\"0\" y=\"20\" width=\"52\" height=\"35\" rx=\"3\" fill=\"#111\" stroke=\"#000\" stroke-width=\"1.2\"/>");
            sb.Append("<rect x=\"3\" y=\"23\" width=\"46\" height=\"27\" fill=\"#1e293b\"/>");
            // Hood
            sb.Append("<path d=\"M 10 14 Q 10 -2 26 -2 Q 42 -2 42 14 L 42 30 L 10 30 Z\" fill=\"#111\" stroke=\"#111\"/>");
            // Eyes strip
            sb.Append("<rect x=\"18\" y=\"18\" width=\"16\" height=\"5\" fill=\"#e11d48\"/>");
            sb.Append("</g>");
            return sb.ToString();
        }

        // --- helpers -----------------------------------------------------------

        private static readonly string[] _winKeywords = { "windows", "microsoft" };
        private static readonly string[] _linuxKeywords = {
            "linux", "ubuntu", "debian", "centos", "rhel", "redhat",
            "kali", "arch", "fedora", "suse", "alpine", "unix"
        };

        private static bool IsWindowsBox(Box b)
        {
            var os = (b.Os ?? "").ToLowerInvariant();
            var hn = (b.Hostname ?? "").ToLowerInvariant();
            if (_winKeywords.Any(k => os.Contains(k))) return true;
            if (_winKeywords.Any(k => hn.Contains(k))) return true;
            if (_linuxKeywords.Any(k => hn.Contains(k))) return false;
            if (hn.StartsWith("win") || hn.Contains("-win") || hn.Contains(" win")) return true;
            if (hn.StartsWith("dc") || hn.Contains("exchange") || hn.Contains("srv-win")) return true;
            return false;
        }

        private static string XmlEscape(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("&", "&amp;").Replace("<", "&lt;")
                    .Replace(">", "&gt;").Replace("\"", "&quot;")
                    .Replace("'", "&apos;");
        }

        private static string Ellipsize(string s, int max) =>
            (s?.Length ?? 0) <= max ? (s ?? "") : s.Substring(0, max - 1) + "…";
    }
}
