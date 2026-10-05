import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from .config import SimulationConfig
from .paths import RUN_ROOT
from .pipeline import simulate


def main(argv=None, *, gui_default=False):
    parser = argparse.ArgumentParser(description="Render a spacecraft and generate event-camera data.")
    parser.add_argument("--nogui", action="store_true", help="Run without opening the desktop GUI")
    parser.add_argument(
        "--filename",
        "--config",
        dest="config",
        type=Path,
        help="JSON simulation configuration (defaults to demo spacecraft)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Empty output directory (default: a new timestamped folder under simulator-runs)",
    )
    args = parser.parse_args(argv)
    if gui_default and not args.nogui:
        if args.config is not None or args.output is not None:
            parser.error("Use --nogui with --filename/--config or --output to run a simulation.")
        # Keep Qt and Matplotlib out of headless runs, including on machines without a display.
        from .gui import main as gui_main

        return gui_main()
    try:
        config = (
            SimulationConfig.from_dict(json.loads(args.config.read_text(encoding="utf-8")))
            if args.config
            else SimulationConfig()
        )
        output = args.output or RUN_ROOT / datetime.now(timezone.utc).strftime(
            "run-%Y%m%d-%H%M%S-%f"
        )
        print(f"Output directory: {output.resolve()}", flush=True)
        simulate(config, output, lambda message: print(message, flush=True))
    except (ValueError, TypeError, RuntimeError, OSError, InterruptedError) as exc:
        parser.exit(1, f"Simulation failed: {exc}\n")


def launch(argv=None):
    """Unified desktop/headless entry point; no arguments opens the GUI."""
    return main(argv, gui_default=True)


if __name__ == "__main__":
    main()
