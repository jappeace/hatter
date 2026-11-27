package me.jappie.hatter;

import android.content.Context;
import android.view.View;
import android.widget.LinearLayout;

/**
 * A column or row whose children stretched across it count with their own
 * size, as in a flexbox. A LinearLayout that wraps its content takes its
 * size across from the children that aren't stretched alone, when there are
 * any, and cuts the stretched ones to it.
 */
public class HatterLinearLayout extends LinearLayout {
    public HatterLinearLayout(Context context) {
        super(context);
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        super.onMeasure(widthSpec, heightSpec);
        boolean column = getOrientation() == VERTICAL;
        int acrossSpec = column ? widthSpec : heightSpec;
        // With only stretched children, LinearLayout already counts them.
        if (MeasureSpec.getMode(acrossSpec) == MeasureSpec.EXACTLY
                || !(has(column, true) && has(column, false))) {
            return;
        }
        int padding = column ? getPaddingLeft() + getPaddingRight()
                             : getPaddingTop() + getPaddingBottom();
        int wanted = column ? getMeasuredWidth() : getMeasuredHeight();
        for (int i = 0; i < getChildCount(); i++) {
            View child = getChildAt(i);
            if (child.getVisibility() == GONE || !stretched(column, child)) {
                continue;
            }
            LayoutParams params = (LayoutParams) child.getLayoutParams();
            int margins = column ? params.leftMargin + params.rightMargin
                                 : params.topMargin + params.bottomMargin;
            int own = getChildMeasureSpec(acrossSpec, padding + margins, LayoutParams.WRAP_CONTENT);
            int along = MeasureSpec.makeMeasureSpec(
                column ? child.getMeasuredHeight() : child.getMeasuredWidth(), MeasureSpec.EXACTLY);
            child.measure(column ? own : along, column ? along : own);
            wanted = Math.max(wanted, padding + margins
                + (column ? child.getMeasuredWidth() : child.getMeasuredHeight()));
        }
        if (MeasureSpec.getMode(acrossSpec) == MeasureSpec.AT_MOST) {
            wanted = Math.min(wanted, MeasureSpec.getSize(acrossSpec));
        }
        int exactly = MeasureSpec.makeMeasureSpec(wanted, MeasureSpec.EXACTLY);
        super.onMeasure(column ? exactly : widthSpec, column ? heightSpec : exactly);
    }

    private boolean has(boolean column, boolean stretched) {
        for (int i = 0; i < getChildCount(); i++) {
            View child = getChildAt(i);
            if (child.getVisibility() != GONE && stretched(column, child) == stretched) {
                return true;
            }
        }
        return false;
    }

    private static boolean stretched(boolean column, View child) {
        LayoutParams params = (LayoutParams) child.getLayoutParams();
        return (column ? params.width : params.height) == LayoutParams.MATCH_PARENT;
    }
}
