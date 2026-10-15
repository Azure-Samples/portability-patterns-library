# Diagrams

Architecture and business-continuity diagrams for this application, plus the
code that generates them.

## Files

| File | What it is |
| --- | --- |
| [`oms-business-continuity.svg`](./oms-business-continuity.svg) | **Slide 1 — business story.** What the app does, the continuity journey, why failover is safe. |
| [`azure-vs-azure-local-realicons.svg`](./azure-vs-azure-local-realicons.svg) | **Slide 2 — architecture detail,** with official product icons. |
| [`azure-vs-azure-local-icons.svg`](./azure-vs-azure-local-icons.svg) | Same as slide 2, with neutral geometry instead of product icons. |
| `*.excalidraw` | Editable models, openable at <https://aka.ms/excalidraw>. |
| [`src/`](./src) | Generator scripts. |
| [`icons/`](./icons) | The 16 product icons the diagrams embed. |

## Using them in a demo

Run slide 1 first, then slide 2. They are deliberately split by audience and
carry no overlapping content.

| Topic | Slide 1 | Slide 2 |
| --- | :---: | :---: |
| Order lifecycle and business flow | ● | — |
| Disruption scenarios | ● | — |
| Failover narrative and timeline | ● | — |
| Business guarantees (idempotency, write ordering) | ● | — |
| Radius resource contracts and recipes | — | ● |
| Azure resource types and policy gates | — | ● |
| Identity model detail (FIC, Keycloak, AD DS, AD CS) | — | ● |
| Protocol and durability impact | — | ● |

Slide 1 ends by pointing at slide 2 for the detail, so the handover is built in.

**Out of scope in both:** moving the order data. Replication, seeding and
reconciliation between environments is a separate workstream. Both diagrams say
so explicitly rather than implying the problem away.

## Regenerating

Requires Node.js 18+. No npm install — the scripts use only the standard
library. Run from this directory.

```bash
# slide 1 — business story (model + svg in one step)
node src/gen-oms.mjs oms-business-continuity.excalidraw oms-business-continuity.svg icons

# slide 2 — build the model first, then render each variant
node src/gen-diagram.mjs azure-vs-azure-local.excalidraw
node src/to-svg-real.mjs azure-vs-azure-local.excalidraw azure-vs-azure-local-realicons.svg icons
node src/to-svg2.mjs     azure-vs-azure-local.excalidraw azure-vs-azure-local-icons.svg --icons
```

Edit the text and layout in the `src/*.mjs` files, not in the `.svg` output —
the SVGs are build artifacts and are overwritten on every run.

### How the two slides are built differently

Slide 1 writes its model and renders its SVG in a single script. Slide 2 splits
the two steps so the same model can render twice, once with product icons and
once with neutral geometry. That is the only structural difference.

### Checking a change

The generators do not validate layout. After editing, confirm no box overlaps
another and no label overflows its box:

```powershell
$j = Get-Content oms-business-continuity.excalidraw -Raw | ConvertFrom-Json
$leaf = $j.elements | Where-Object { $_.type -eq 'rectangle' -and $_.boundElements }
for ($i=0; $i -lt $leaf.Count; $i++) {
  for ($k=$i+1; $k -lt $leaf.Count; $k++) {
    $a=$leaf[$i]; $b=$leaf[$k]
    $ox=[Math]::Min($a.x+$a.width,$b.x+$b.width)-[Math]::Max($a.x,$b.x)
    $oy=[Math]::Min($a.y+$a.height,$b.y+$b.height)-[Math]::Max($a.y,$b.y)
    if ($ox -gt 0 -and $oy -gt 0) { "OVERLAP $($a.id) <-> $($b.id)" }
  }
}
foreach ($b in $leaf) {
  $t = $j.elements | Where-Object { $_.containerId -eq $b.id }
  $need = [Math]::Round($t.fontSize * 1.25 * (($t.text -split "`n").Count))
  if ($need -gt $b.height) { "OVERFLOW $($b.id): needs $need has $($b.height)" }
}
```

Both should print nothing. Growing a box's text usually means growing its
height and shifting everything below it.

## Icons

`icons/` holds only the 16 icons these diagrams use, not a full icon pack.

| Source | Icons | Terms |
| --- | --- | --- |
| [Azure architecture icons](https://learn.microsoft.com/en-us/azure/architecture/icons/) | SQL Database, SQL Server, Storage Accounts, Service Bus, Container Registries, Kubernetes Services, Arc Kubernetes, Azure Local, Policy, Azure Arc | Permitted in architectural diagrams and documentation |
| [Microsoft Entra architecture icons](https://learn.microsoft.com/en-us/entra/architecture/architecture-icons) | Entra ID, Entra Workload ID | Same |
| [CNCF artwork](https://github.com/cncf/artwork) | Radius, Keycloak | Project marks for their respective projects |
| Simple Icons | RabbitMQ | CC0 |
| Wikimedia Commons | Azure brand logo | The Microsoft icon pack is service icons only and has no brand mark |

Microsoft's terms say: don't crop, flip, rotate or distort the icons, and keep
the product name near the icon. The renderers honour this — each icon is placed
in a nested `<svg>` with `preserveAspectRatio="xMidYMid meet"`, so it is scaled
uniformly and letterboxed rather than stretched, and every icon sits beside its
product name.

Components with no official mark — the application's own workers, on-prem
AD DS, AD CS — use neutral geometry rather than borrowing an unrelated product
icon, which the terms also prohibit.

### Adding an icon

1. Drop the SVG into `icons/`.
2. Reference it by filename in the generator's icon map.

The loader searches `icons/` recursively, namespaces each icon's internal IDs
and CSS classes on import, and so avoids gradient and stylesheet collisions
between icons that happen to use the same internal names. This matters in
practice: several Azure icons use identical `linearGradient` ids, and CNCF
artwork ships `.cls-1`, `.cls-2` style blocks that are document-global in SVG.
