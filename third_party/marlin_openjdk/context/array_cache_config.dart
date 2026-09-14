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

/// Constants and configuration for ArrayCache
class ArrayCacheConfig {
  static const int buckets = 4;
  static const int minArraySize = 4096;
  static late final int maxArraySize;
  static final List<int> arraySizes = List<int>.filled(buckets, 0);

  static const int minDirtyByteArraySize = 32 * 2048;
  static late final int maxDirtyByteArraySize;
  static final List<int> dirtyByteArraySizes = List<int>.filled(buckets, 0);

  // threshold to grow arrays only by (3/2) instead of 2
  static late final int thresholdArraySize;

  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;

    int arraySize = minArraySize;
    for (int i = 0; i < buckets; i++, arraySize <<= 2) {
      arraySizes[i] = arraySize;
    }
    maxArraySize = arraySize >> 2;

    arraySize = minDirtyByteArraySize;
    for (int i = 0; i < buckets; i++, arraySize <<= 1) {
      dirtyByteArraySizes[i] = arraySize;
    }
    maxDirtyByteArraySize = arraySize >> 1;

    int t = 2 * 1024 * 1024;
    thresholdArraySize = t > maxArraySize ? t : maxArraySize;
  }

  static int getBucket(int length) {
    if (!_initialized) init();
    for (int i = 0; i < arraySizes.length; i++) {
      if (length <= arraySizes[i]) {
        return i;
      }
    }
    return -1;
  }

  static int getBucketDirtyBytes(int length) {
    if (!_initialized) init();
    for (int i = 0; i < dirtyByteArraySizes.length; i++) {
      if (length <= dirtyByteArraySizes[i]) {
        return i;
      }
    }
    return -1;
  }

  static int getNewSize(int curSize, int needSize) {
    if (!_initialized) init();
    // initial = (curSize & MASK_CLR_1) -> simply curSize here as we don't assume bits
    int size;
    if (curSize > thresholdArraySize) {
      size = (curSize * 3) >> 1; // 1.5x
    } else {
      size = curSize << 1; // 2x
    }
    if (size < needSize) {
      size = needSize;
    }
    return size;
  }
}
