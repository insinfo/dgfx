class Edge {
  int yStart; // Start Scanline (inclusive)
  int yEnd; // End Scanline (exclusive)

  int x; // Fixed point X at yStart
  int fullX = 0; // Integer part of X (cache)
  int slope; // Fixed point increment per scanline
  int slopeFix; // Correction for DDA drift if needed (SLEFA mentions it)

  int dir; // +1 or -1 (winding)

  Edge? next; // For linked list in AET

  Edge({
    required this.yStart,
    required this.yEnd,
    required this.x,
    required this.slope,
    required this.dir,
    this.slopeFix = 0,
  });
}
