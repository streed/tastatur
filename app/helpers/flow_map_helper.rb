module FlowMapHelper
  # The journey tree drawn as a directed graph, left to right.
  #
  # WHY A GRAPH AND NOT THE LIST. The list of levels underneath this is the same
  # data and is not going away — it carries the exact figures, the suppression
  # prose, and the only rendering that survives with no CSS. What it cannot do is
  # show SHAPE. Three stacked cards make the reader hold the connection between
  # them in their head: card two is "what happened after the row I clicked in
  # card one", and nothing on screen says which row that was. Drawn as a tree the
  # connection is a line, the walked route is a spine, and the question the report
  # exists to answer — where do people go, and how many are left by the time they
  # get there — is legible without reading a number.
  #
  # THE EDGE WEIGHT IS A PROBABILITY, and that is the whole reading of the
  # picture. Its width is `Branch#percentage`: the share of the visitors AT THAT
  # NODE who took that branch, counted in PostgreSQL by Analytics::PageFlow
  # (COUNT(DISTINCT visitor_hash) on the branch over the same at the node). It is
  # a transition probability, not a share of the site — so the edges leaving one
  # node sum to 100% and edges at different depths are not comparable by width
  # across the picture, only within a fan. The number is printed on the edge for
  # that reason: a reader comparing two thicknesses in different columns is
  # asking a question the picture cannot answer, and the labels are what stop the
  # width from being the only thing to read.
  #
  # The node carries the POPULATION (visitors) and the edge carries the
  # PROBABILITY. Splitting them that way is deliberate: they are different
  # quantities, and a node that repeated the percentage would invite the reader
  # to add the percentages down a column, which is exactly the mistake §8 records
  # for distinct counts and §18 for lifetime revenue.
  #
  # NO CHARTING LIBRARY, for the reason ChartHelper states at greater length: a
  # privacy tool that pulls a graph-layout bundle to draw eleven boxes is not
  # making the argument it claims to. The layout is a tidy tree computed here in
  # about forty lines, the edges are one inline SVG, and the nodes are ordinary
  # anchors positioned over it — so they truncate long paths with CSS, take a
  # focus ring, and work with JavaScript off.
  #
  # SUPPRESSION IS DRAWN, not omitted. A withheld fan appears as its own muted
  # node at the end of the level it belongs to. Leaving it out would make a
  # partially-suppressed node look like a complete one, which is the three-state
  # rule sites/_breakdown carries: nothing here, and nothing shown, are different
  # facts. The terminal branch is drawn for the same reason it is counted —
  # "left the site" is usually the biggest edge on the picture, and a tree that
  # hid it would show a site nobody ever leaves.

  NODE_W = 200
  NODE_H = 44
  # Row pitch. The gap (12px) is what keeps two adjacent nodes from reading as
  # one block; the edges arriving between them need somewhere to land.
  ROW = 56
  GAP = 68
  PAD_X = 12
  PAD_Y = 10

  # Hairline to a heavy rule, over the full 0-100% range. The floor is not zero:
  # a 1% branch that rendered as a 0.1px line would be invisible, and an edge you
  # cannot see is a branch the reader concludes does not exist.
  STROKE_MIN = 1.5
  STROKE_MAX = 14.0

  Node = Struct.new(:label, :sub, :title, :href, :x, :y, :spine, :current, :quiet,
                    keyword_init: true)
  Edge = Struct.new(:d, :width, :label, :label_x, :label_y, :spine, :terminal, :dashed,
                    keyword_init: true)

  Map = Struct.new(:nodes, :edges, :width, :height, keyword_init: true)

  # site, path (Array<Analytics::FlowStep>), levels (Array<PageFlow::Result>)
  def flow_map(site, path, levels)
    map = flow_map_layout(site, path, levels)
    return if map.nodes.size < 2

    tag.div(class: "flow-map", role: "group",
            aria: { label: "Flow map from #{flow_step_text(path.first)}" }) do
      tag.div(class: "flow-map-canvas", style: "width: #{map.width}px; height: #{map.height}px") do
        safe_join([flow_map_edges(map), *map.nodes.map { |node| flow_map_node(node) }])
      end
    end
  end

  private

  # A tidy tree over a spine.
  #
  # Every node the reader has NOT walked into is a leaf and takes one row. The
  # one they did walk into is expanded, so its own fan occupies the rows beneath
  # it, and it is centred on that fan rather than on a row of its own — which is
  # what makes the spine read as a spine instead of as a diagonal. Rows are
  # allocated by a single cursor in document order, so the vertical order of the
  # picture is the ranking order of the lists below it, and the two can be read
  # against each other.
  def flow_map_layout(site, path, levels)
    nodes = []
    edges = []
    cursor = 0

    place = lambda do |depth|
      result = levels[depth]
      children = []
      wanted = path[depth + 1]

      # THE WALKED PATH IS ALWAYS ON THE MAP, even where the branch that would
      # carry it is not among the ones drawn. Two ways to get here: a
      # hand-edited URL naming a step nobody took, and a step whose branch was
      # withheld by k-anonymity one level up. In both, the breadcrumb, the
      # heading and the card below all say the reader is standing somewhere, and
      # a picture that quietly dropped that step would be the one thing on screen
      # disagreeing with the rest — which reads as the map being broken rather
      # than as the route being empty. It arrives with no share on its edge: nil
      # and withheld are different, and neither is a number we may print.
      if wanted && Array(result&.branches).none? { |branch| !branch.terminal? && branch.step == wanted }
        center = place.call(depth + 1)
        children << [center, :unmatched, true]
        nodes << flow_unmatched_node(site, path, depth + 1, center, levels)
      end

      Array(result&.branches).each do |branch|
        child_depth = depth + 1
        walked = !branch.terminal? && branch.step == path[child_depth]

        # The walked branch is laid out first so its subtree claims the rows it
        # needs; everything else is a single row taken as it comes.
        center = walked ? place.call(child_depth) : (cursor += 1) - 1
        children << [center, branch, walked]
        nodes << flow_branch_node(site, path, branch, child_depth, center, walked, levels)
      end

      # Drawn even when it is the ONLY child — a level whose every branch was
      # withheld must not render as a node people simply stopped at. Same
      # three-state rule sites/_flow_branches states at greater length.
      if result&.suppressed?
        center = (cursor += 1) - 1
        children << [center, :withheld, false]
        nodes << flow_withheld_node(result, depth + 1, center)
      end

      # A node nobody went anywhere from: it still needs a row of its own.
      return (cursor += 1) - 1 if children.empty?

      rows = children.map(&:first)
      parent = (rows.min + rows.max) / 2.0
      children.each { |row, branch, walked| edges << flow_map_edge(depth, parent, row, branch, walked) }
      parent
    end

    root_row = place.call(0)
    nodes << flow_root_node(site, path, levels, root_row)

    columns = nodes.map { |node| flow_map_depth(node.x) }.max + 1

    Map.new(
      nodes: nodes,
      edges: edges,
      width: (PAD_X * 2) + (columns * NODE_W) + ((columns - 1) * GAP),
      height: (PAD_Y * 2) + ([cursor, 1].max * ROW)
    )
  end

  def flow_map_x(depth) = PAD_X + (depth * (NODE_W + GAP))
  def flow_map_y(row) = PAD_Y + (row * ROW) + (ROW / 2.0)

  # The step the tree is rooted at. It links back to itself only when there is
  # something to collapse, so the opening view has no link that does nothing.
  def flow_root_node(site, path, levels, row)
    Node.new(
      label: flow_step_label(path.first),
      sub: "#{metric_number(levels.first.visitors)} visitors",
      title: "#{metric_number(levels.first.visitors)} visitors reached " \
             "#{flow_step_text(path.first)}",
      href: (journey_url(site, path.first(1)) if path.size > 1),
      x: flow_map_x(0), y: flow_map_y(row),
      spine: true, current: path.size == 1
    )
  end

  def flow_branch_node(site, path, branch, depth, row, walked, levels)
    # A branch is expandable while the path it would produce fits the depth cap,
    # which is the same test sites/_flow_branches makes one level up.
    expandable = !branch.terminal? && depth < Analytics::PageFlow::MAX_DEPTH
    current = walked && depth == path.size - 1
    prefix = path.first(depth)

    href =
      if walked then (journey_url(site, path.first(depth + 1)) unless current)
      elsif expandable then journey_url(site, prefix + [branch.step])
      end

    # A branch back to somewhere already on the walked path, marked here for the
    # reason DashboardHelper#flow_return? gives — and it is worth more on the
    # picture than in the list, because a tree drawn strictly left to right is
    # the one rendering in which a loop looks exactly like progress.
    sub = "#{metric_number(branch.visitors)} visitors"
    sub += " · returned" if flow_return?(branch, prefix)

    Node.new(
      label: flow_branch_label(branch, levels.first.direction),
      sub: sub,
      title: flow_map_node_title(branch, levels.first.direction),
      href: href,
      x: flow_map_x(depth), y: flow_map_y(row),
      spine: walked, current: current, quiet: branch.terminal?
    )
  end

  # Said as a sentence, because the map's numbers are split across the node and
  # the edge and a reader hovering one wants both.
  def flow_map_node_title(branch, direction)
    return "#{metric_number(branch.visitors)} visitors — #{flow_branch_label(branch, direction)}" if branch.terminal?

    "#{branch.percentage.round}% of visitors here (#{metric_number(branch.visitors)}) " \
      "went to #{flow_step_text(branch.step)}. Where visitors went after " \
      "#{flow_step_text(branch.step)}"
  end

  # A walked step that no drawn branch accounts for. Still on the spine, because
  # it is where the reader is; still carrying its own visitor count, because the
  # card for this level prints exactly that number already.
  def flow_unmatched_node(site, path, depth, row, levels)
    current = depth == path.size - 1
    visitors = levels[depth].visitors

    Node.new(
      label: flow_step_label(path[depth]),
      sub: "#{metric_number(visitors)} visitors",
      title: "#{metric_number(visitors)} visitors reached #{flow_step_text(path[depth])}",
      href: (journey_url(site, path.first(depth + 1)) unless current),
      x: flow_map_x(depth), y: flow_map_y(row),
      spine: true, current: current
    )
  end

  # The fan that k-anonymity removed, as a node of its own. Not a link: the
  # branches behind it are exactly what may not be walked into.
  def flow_withheld_node(result, depth, row)
    Node.new(
      label: pluralize(result.suppressed_rows, "branch", plural: "branches") + " withheld",
      sub: "#{metric_number(result.suppressed_visitors)} visitors",
      title: "Withheld because each branch was taken by fewer than " \
             "#{result.threshold} visitors",
      x: flow_map_x(depth), y: flow_map_y(row), quiet: true
    )
  end

  # An elbow, not a curve. The house style has no radius anywhere (see the
  # stylesheet header), and a right-angled run also makes it possible to follow
  # one edge through a crowded fan, which a bundle of beziers does not.
  def flow_map_edge(depth, parent_row, child_row, branch, walked)
    x1 = flow_map_x(depth) + NODE_W
    x2 = flow_map_x(depth + 1)
    y1 = flow_map_y(parent_row)
    y2 = flow_map_y(child_row)
    mid = x1 + (GAP / 2)

    # Neither of these has a share to draw: one is withheld, the other was never
    # measured as a branch at all. Both get a hairline and no label.
    unmeasured = branch == :withheld || branch == :unmatched
    # The probability, straight off the branch. See the note at the top of this
    # file for why it is the width AND is printed.
    share = unmeasured ? 0 : branch.percentage

    Edge.new(
      d: y1 == y2 ? "M#{x1},#{y1} H#{x2}" : "M#{x1},#{y1} H#{mid} V#{y2} H#{x2}",
      width: (STROKE_MIN + ((share.clamp(0, 100) / 100.0) * (STROKE_MAX - STROKE_MIN))).round(2),
      label: ("#{share.round}%" unless unmeasured),
      label_x: x2 - 8, label_y: y2 - 6,
      spine: walked,
      terminal: unmeasured || branch.terminal?,
      dashed: branch == :unmatched
    )
  end

  # One SVG behind the nodes, sized to the same canvas. aria-hidden because the
  # percentages it carries are floating numbers with nothing to attach them to
  # in a reading order — every one of them is on screen as real text in the
  # level lists below, which is the accessible rendering of this picture.
  def flow_map_edges(map)
    tag.svg(class: "flow-edges", width: map.width, height: map.height,
            viewBox: "0 0 #{map.width} #{map.height}", aria: { hidden: "true" }) do
      safe_join(map.edges.map { |edge| flow_map_edge_marks(edge) })
    end
  end

  def flow_map_edge_marks(edge)
    color = edge.terminal ? "var(--color-rule-2)" : "var(--color-signal)"

    safe_join([
      tag.path(d: edge.d, fill: "none", stroke: color,
               "stroke-width": edge.width,
               "stroke-dasharray": ("3 3" if edge.dashed),
               # The unwalked branches are washed back so the route the reader is
               # actually on stays findable in a fan of eight.
               "stroke-opacity": edge.spine ? "0.85" : "0.30"),
      (tag.text(edge.label, x: edge.label_x, y: edge.label_y,
                class: "flow-edge-label", "text-anchor": "end") if edge.label)
    ].compact)
  end

  def flow_map_node(node)
    body = safe_join([
      tag.span(node.label, class: "flow-node-label"),
      tag.span(node.sub, class: "flow-node-sub num")
    ])

    data = { spine: node.spine.to_s, current: node.current.to_s, quiet: node.quiet.to_s }
    attrs = {
      class: "flow-node",
      title: node.title,
      style: "left: #{node.x}px; top: #{(node.y - (NODE_H / 2.0)).round(1)}px; " \
             "width: #{NODE_W}px; height: #{NODE_H}px",
      data: data
    }

    return tag.div(body, **attrs) if node.href.blank?

    # Only the SHAPE of the interaction is reported, never the customer's own
    # paths — the rule sites/_flow_branches follows for the same links.
    link_to(body, node.href, **attrs, "aria-current": node.current.to_s,
            data: data.merge(analytics_event: "Journey Expanded",
                             analytics_props: { depth: flow_map_depth(node.x), surface: "map" }))
  end

  def flow_map_depth(x) = ((x - PAD_X) / (NODE_W + GAP)).round
end
