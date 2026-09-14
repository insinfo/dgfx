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

class IntArrayCache {
  final int arraySize;
  final List<Int32List> _arrays = [];

  IntArrayCache(this.arraySize);

  Int32List getArray() {
    if (_arrays.isNotEmpty) {
      return _arrays.removeLast();
    }
    return Int32List(arraySize);
  }

  void putDirtyArray(Int32List array, int length) {
    if (length != arraySize) {
      // System.out.println("bad length = " + length);
      return;
    }
    _arrays.add(array);
  }

  void putArray(Int32List array, int length, int fromIndex, int toIndex) {
    if (length != arraySize) {
      return;
    }
    if (toIndex != 0) {
      array.fillRange(fromIndex, toIndex, 0);
    }
    _arrays.add(array);
  }

  static void fill(Int32List array, int fromIndex, int toIndex, int value) {
    if (toIndex != 0) {
      array.fillRange(fromIndex, toIndex, value);
    }
  }
}
