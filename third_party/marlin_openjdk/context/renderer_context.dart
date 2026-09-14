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

import 'dart:typed_data';
import 'array_cache_config.dart';
import 'int_array_cache.dart';
import 'float_array_cache.dart';
import 'byte_array_cache.dart';
// import '../marlin_renderer.dart';

class RendererContext {
  static final RendererContext _instance = RendererContext("ctx0");

  static RendererContext createContext() {
    return _instance;
  }

  final String name;
  final ArrayCachesHolder _holder;
  // MarlinRenderer? renderer; // circular dependency handling

  RendererContext(this.name) : _holder = ArrayCachesHolder();

  ArrayCachesHolder getArrayCachesHolder() => _holder;

  // IntArrayCache
  IntArrayCache getIntArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucket(length);
    return _holder.intArrayCaches[bucket];
  }

  List<int> getIntArray(int length) {
    // returns Int32List but type as List for flexibility
    if (length <= ArrayCacheConfig.maxArraySize) {
      return getIntArrayCache(length).getArray();
    }
    return List<int>.filled(length, 0); // fallback, though Int32List preferred
  }

  // Dirty Int
  IntArrayCache getDirtyIntArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucket(length);
    return _holder.dirtyIntArrayCaches[bucket];
  }

  // Float
  FloatArrayCache getDirtyFloatArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucket(length);
    return _holder.dirtyFloatArrayCaches[bucket];
  }

  // Byte
  ByteArrayCache getDirtyByteArrayCache(int length) {
    final bucket = ArrayCacheConfig.getBucketDirtyBytes(length);
    return _holder.dirtyByteArrayCaches[bucket];
  }

  // Int32List Reuse
  void putIntArray(Int32List array, int fromIndex, int toIndex) {
    if (array.length <= ArrayCacheConfig.maxArraySize) {
      final bucket = ArrayCacheConfig.getBucket(array.length);
      _holder.intArrayCaches[bucket]
          .putArray(array, array.length, fromIndex, toIndex);
    }
  }

  void putDirtyIntArray(Int32List array) {
    if (array.length <= ArrayCacheConfig.maxArraySize) {
      final bucket = ArrayCacheConfig.getBucket(array.length);
      _holder.dirtyIntArrayCaches[bucket].putDirtyArray(array, array.length);
    }
  }

  void putDirtyByteArray(Uint8List array) {
    if (array.length <= ArrayCacheConfig.maxArraySize) {
      final bucket = ArrayCacheConfig.getBucketDirtyBytes(array.length);
      _holder.dirtyByteArrayCaches[bucket].putDirtyArray(array, array.length);
    }
  }
}

class ArrayCachesHolder {
  late final List<IntArrayCache> intArrayCaches;
  late final List<IntArrayCache> dirtyIntArrayCaches;
  late final List<FloatArrayCache> dirtyFloatArrayCaches;
  late final List<ByteArrayCache> dirtyByteArrayCaches;

  ArrayCachesHolder() {
    ArrayCacheConfig.init();
    final buckets = ArrayCacheConfig.buckets;

    intArrayCaches = List.generate(
        buckets, (i) => IntArrayCache(ArrayCacheConfig.arraySizes[i]));
    dirtyIntArrayCaches = List.generate(
        buckets, (i) => IntArrayCache(ArrayCacheConfig.arraySizes[i]));
    dirtyFloatArrayCaches = List.generate(
        buckets, (i) => FloatArrayCache(ArrayCacheConfig.arraySizes[i]));
    dirtyByteArrayCaches = List.generate(buckets,
        (i) => ByteArrayCache(ArrayCacheConfig.dirtyByteArraySizes[i]));
  }
}
