/*
 * Copyright (c) 2007, 2015, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

/*
 * MODIFICADO: este arquivo e uma traducao para Dart do Marlin renderer do
 * OpenJDK (org.marlin.pisces / sun.java2d.marlin), feita por Isaque Neves em
 * 2026. A traducao e uma obra derivada e permanece sob a GNU General Public
 * License versao 2 com a Classpath Exception, exatamente como o original.
 *
 * Este diretorio NAO faz parte do pacote `dgfx` publicado no pub.dev, que e
 * licenciado sob MIT. Veja `third_party/marlin_openjdk/README.md`.
 */

/// Marlin constant holder
abstract class MarlinConst {
  // Subpixels expressed as log2
  static const int subpixelLgPositionsX = 3; // 8 subpixels
  static const int subpixelLgPositionsY = 3; // 8 subpixels

  // Number of subpixels
  static const int subpixelPositionsX = 1 << subpixelLgPositionsX; // 8
  static const int subpixelPositionsY = 1 << subpixelLgPositionsY; // 8

  // Subpixel masks
  static const int subpixelMaskX = subpixelPositionsX - 1; // 7
  static const int subpixelMaskY = subpixelPositionsY - 1; // 7

  // Max anti-aliasing alpha
  static const int maxAAAlpha = subpixelPositionsX * subpixelPositionsY; // 64

  // Tile size
  static const int tileSizeLg = 5; // 32 pixels
  static const int tileSize = 1 << tileSizeLg;

  // Initial array sizes
  static const int initialPixelDim = 2048;
  static const int initialArray = 256;
  static const int initialSmallArray = 1024;
  static const int initialMediumArray = 4096;
  static const int initialLargeArray = 8192;
  static const int initialArray16K = 16384;
  static const int initialArray32K = 32768;
  static const int initialAAArray = initialPixelDim;

  // Initial edges capacity (6 ints per edge)
  static const int initialEdgesCapacity = 4096 * 6;

  // Initial bucket array size
  static const int initialBucketArray = initialPixelDim * subpixelPositionsY;

  // Winding rules
  static const int windEvenOdd = 0;
  static const int windNonZero = 1;

  // Edge structure offsets
  static const int offCurX = 0;
  static const int offError = 1;
  static const int offBumpX = 2;
  static const int offBumpErr = 3;
  static const int offNext = 4;
  static const int offYmaxOr = 5;
  static const int sizeofEdge = 6;

  // Subpixel conversion constants
  static const double fSubpixelPositionsX = 8.0; // subpixelPositionsX as double
  static const double fSubpixelPositionsY = 8.0; // subpixelPositionsY as double

  // Power of 2^32 for fixed-point arithmetic
  static const double power2To32 = 4294967296.0; // 2^32

  // Cubic curve flattening constants
  static const int cubCountLg = 2;
  static const int cubCount = 1 << cubCountLg; // 4
  static const int cubCount2 = 1 << (2 * cubCountLg); // 16
  static const int cubCount3 = 1 << (3 * cubCountLg); // 64
  static const double cubInvCount = 1.0 / cubCount;
  static const double cubInvCount2 = 1.0 / cubCount2;
  static const double cubInvCount3 = 1.0 / cubCount3;
}
