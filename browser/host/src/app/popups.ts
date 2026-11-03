// Hatter's dialogs (DialogBridge.h) and bottom sheets (BottomSheetBridge.h)
// as Material ones. Each answers with the action code its bridge expects.
// Also short notes, as Android's toasts.

import { Component, Injectable, inject } from '@angular/core';
import { MatBottomSheet, MAT_BOTTOM_SHEET_DATA, MatBottomSheetRef } from '@angular/material/bottom-sheet';
import { MatButton } from '@angular/material/button';
import {
  MAT_DIALOG_DATA,
  MatDialog,
  MatDialogActions,
  MatDialogClose,
  MatDialogContent,
  MatDialogTitle,
} from '@angular/material/dialog';
import { MatActionList, MatListItem, MatListSubheaderCssMatStyler } from '@angular/material/list';
import { MatSnackBar } from '@angular/material/snack-bar';
import { Observable } from 'rxjs';

/** DialogBridge.h's code for a dialog closed without a button. */
const dialogDismissed = 3;

/** BottomSheetBridge.h's code for a sheet closed without an item. */
const sheetDismissed = -1;

interface Button {
  label: string;
  /** Which of the app's buttons it is, as DialogBridge.h numbers them. */
  action: number;
}

interface DialogData {
  title: string;
  message: string;
  buttons: Button[];
}

interface SheetData {
  title: string;
  items: string[];
}

@Component({
  selector: 'hatter-dialog',
  imports: [MatButton, MatDialogActions, MatDialogClose, MatDialogContent, MatDialogTitle],
  template: `
    @if (data.title) {
      <h2 mat-dialog-title>{{ data.title }}</h2>
    }
    @if (data.message) {
      <mat-dialog-content>{{ data.message }}</mat-dialog-content>
    }
    <mat-dialog-actions align="end">
      @for (button of data.buttons; track button.action) {
        <button matButton [mat-dialog-close]="button.action">{{ button.label }}</button>
      }
    </mat-dialog-actions>`,
  styles: 'mat-dialog-content { white-space: pre-wrap; }',
})
class DialogPopup {
  readonly data: DialogData = inject(MAT_DIALOG_DATA);
}

@Component({
  selector: 'hatter-sheet',
  imports: [MatActionList, MatListItem, MatListSubheaderCssMatStyler],
  template: `
    <mat-action-list>
      @if (data.title) {
        <h3 matSubheader>{{ data.title }}</h3>
      }
      @for (item of data.items; track $index) {
        <button mat-list-item (click)="sheet.dismiss($index)">{{ item }}</button>
      }
    </mat-action-list>`,
})
class SheetPopup {
  readonly data: SheetData = inject(MAT_BOTTOM_SHEET_DATA);
  readonly sheet: MatBottomSheetRef<SheetPopup, number> = inject(MatBottomSheetRef);
}

@Injectable({ providedIn: 'root' })
export class Popups {
  private readonly dialogs = inject(MatDialog);
  private readonly sheets = inject(MatBottomSheet);
  private readonly notes = inject(MatSnackBar);
  /** How many are open. */
  private open = 0;

  /** A short note for the user, as Android's toast. */
  note(text: string): void {
    this.notes.open(text, undefined, { duration: 2000 });
  }

  /** A note that stays until the user closes it. */
  notice(text: string): void {
    this.notes.open(text, 'OK');
  }

  /**
   * A dialog's answer. Android puts the first button at the end, the second
   * before it and the third at the start, and so do we.
   */
  dialog(title: string, message: string, labels: string[]): Promise<number> {
    const buttons = labels
      .map((label, action) => ({ label, action }))
      .filter(({ label }) => label)
      .reverse();
    const ref = this.dialogs.open<DialogPopup, DialogData, number>(DialogPopup, {
      data: { title, message, buttons },
      autoFocus: 'dialog',
    });
    return this.answer(ref.afterClosed(), dialogDismissed);
  }

  /** Which of a sheet's items the user picks. */
  sheet(title: string, items: string[]): Promise<number> {
    const ref = this.sheets.open<SheetPopup, SheetData, number>(SheetPopup, {
      data: { title, items },
      autoFocus: 'dialog',
    });
    return this.answer(ref.afterDismissed(), sheetDismissed);
  }

  /** Closes what's open, for Back. Whether anything was. */
  close(): boolean {
    if (!this.open) return false;
    this.dialogs.closeAll();
    this.sheets.dismiss();
    return true;
  }

  /** What a popup closes with, or what its bridge calls closing it. */
  private answer(closed: Observable<number | undefined>, dismissed: number): Promise<number> {
    this.open++;
    return new Promise((resolve) =>
      closed.subscribe((code) => {
        this.open--;
        resolve(code ?? dismissed);
      }),
    );
  }
}
