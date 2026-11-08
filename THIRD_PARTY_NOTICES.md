# Third-party notices

## Device runtime dependency

The Python backend imports `pymobiledevice3==11.49.0`. Its installed distribution
declares `GPL-3.0-or-later` in `License-Expression` and includes the GPL v3 text
in `pymobiledevice3-11.49.0.dist-info/licenses/LICENSE`.

The dependency is installed separately by `uv sync --frozen`; its source and
runtime environment are not included in this repository's source archive.
The project's own license does not replace the licenses of pymobiledevice3 or
its transitive dependencies. Review their notices before distributing bundled
environments, applications, or installers.

## Coordinate conversion

The GCJ-02 forward equations in `Coordinate.swift` are adapted from
[wandergis/coordtransform](https://github.com/wandergis/coordtransform).

The MIT License (MIT)

Copyright (c) 2015 记忆的残骸

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
