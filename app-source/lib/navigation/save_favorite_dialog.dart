import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class SaveFavoriteDialog extends StatefulWidget {
  const SaveFavoriteDialog({
    super.key,
    required this.coords,
    required this.suggestedName,
  });

  final LatLng coords;
  final String suggestedName;

  @override
  State<SaveFavoriteDialog> createState() => _SaveFavoriteDialogState();
}

class _SaveFavoriteDialogState extends State<SaveFavoriteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.suggestedName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('즐겨찾기 추가'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: '장소 이름',
              hintText: '예: 집, 주차장, 촬영 장소',
            ),
          ),
          Text(
            '위도 ${widget.coords.latitude.toStringAsFixed(6)} / '
            '경도 ${widget.coords.longitude.toStringAsFixed(6)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}
