# Standing cadence — opt-in, per project

QA can run on a schedule so quality is checked continuously. **Opt-in per project**; it does
not auto-arm, and a shift never starts one.

```
/schedule create "weekly product QA" --cron "0 9 * * 1" --prompt "/guild:qa product cadence"
```

A `cadence` pass skips full re-planning and asks the board what is due:

```sql
SELECT id, area, risk, interval_days, days_since, spec_path FROM v_coverage_due;
```

`days_since` is **NULL for an area nobody has ever inspected** — that is not "0 days ago", and
reporting it as such lies about the state of the product.

The qa-strategist then declares a single qa-tester mission that (a) runs the existing
regression suite from `.guild/qa/regression.md`, and (b) does a focused exploratory pass on
exactly those areas, filing anything new it finds. **If nothing is due, the pass ends there** —
that is the cadence working, not failing.
