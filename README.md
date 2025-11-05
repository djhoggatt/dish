# dish (Denver's Integrated Shell)

This is a simple command line interface (CLI) written in zig, and intended for use in embedded systems.

This shell:
1. Provides a simple and intuitive interface which allow other modules to easily register commands.
2. Provides enough flexibility to be used in various environments on various terminals.
3. Does not rely on any external libraries, including the standard library.
4. Is simple, efficient, and designed to have a small memory footprint.

Items To Do:
1. Write tests
2. Bug - Pressing-and-holding the up-arrow may result in strange behavior.
3. Bug - Up-arrow sometimes skips by two
4. Implement version command
