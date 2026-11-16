@echo off
title Otimizador Empresarial - Manutencao automatica
rem Limpeza segura + relatorio, sem perguntas. Ideal para tarefa agendada, GPO ou ferramenta de acesso remoto.
rem Para salvar os relatorios numa pasta de rede, use:
rem   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OtimizadorEmpresa.ps1" -Automatico -PastaRelatorio "\\servidor\ti\relatorios"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OtimizadorEmpresa.ps1" -Automatico
