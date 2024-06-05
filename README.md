This is Refresh, a cross-platform hardware-accelerated graphics library with modern capabilities.

License
-------
Refresh is licensed under the zlib license. See LICENSE for details.

About Refresh
-------------
The contemporary graphics landscape is daunting. Older and easier-to-learn APIs like OpenGL are being replaced by explicit APIs like Vulkan.
These newer APIs have many appealing features, like threading support and bundled state management,
but using them in practice requires complex management of memory and synchronization.
What's a developer to do?

Refresh is a middle ground between these two extremes. The API aims for the simplicity of OpenGL combined with the power of Vulkan.
Refresh supports all desktop platforms. Vulkan and D3D11 backends are complete, and Metal support is coming soon.
Refresh supports portable shaders through SPIRV-Cross, but it also allows you to provide backend-specific shader formats, so you can use any shader toolchain you like.

Dependencies
------------
Refresh depends on SDL2 for portability.
Refresh never explicitly uses the C runtime.
SPIRV-Cross is dynamically linked as an optional dependency.

Building Refresh
----------------
For *nix platforms, use CMake:

    $ mkdir build/
    $ cd build/
    $ cmake ../
    $ make

For Windows, use the Refresh.sln in the "visualc" folder.

Want to contribute?
-------------------
Issues can be reported and patches contributed via Github:

https://github.com/MoonsideGames/Refresh
