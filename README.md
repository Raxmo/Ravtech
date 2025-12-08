# Ravtech

A D-based game development library focused on close-to-metal development with high levels of customization. Ravtech prioritizes being an enabler for experimentation rather than a prescriptive framework—designed for developers who want control over their engine architecture.

## Philosophy

**The engine should not get in the way of the developer.**

- Direct access to graphics and audio APIs
- No forced architectural patterns or asset pipelines
- Complete control over your engine design
- Minimal abstraction overhead

## Dependencies

- D compiler (DMD, LDC2, or GDC)
- dub (D's package manager)
- OpenGL
- OpenAL
- GLFW

## Building

```bash
dub build
```

## Running

```bash
dub run
```

## Project Structure

- `source/` - D source code
- `LICENSE/` - License files

## Libraries

- **bindbc-glfw** - GLFW windowing library bindings
- **bindbc-opengl** - OpenGL bindings
- **bindbc-openal** - OpenAL audio bindings
